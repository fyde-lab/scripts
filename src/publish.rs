//! The `publish` command: writes every scraper under `scrapers/` to a fyde
//! server through its admin API (`admin.v1.AdminService`), which only an
//! admin account may call. Talks gRPC to the server directly rather than
//! through `fyde-sdk`'s `Client`: logging in (OPAQUE, over `users.v1`) is the
//! only other thing it needs, and there's nothing worth keeping locally.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{Context, Result, anyhow, bail};
use argon2::{Algorithm, Argon2, Params, Version};
use opaque_ke::ciphersuite::CipherSuite;
use opaque_ke::rand::RngCore as _;
use opaque_ke::rand::rngs::OsRng;
use opaque_ke::{ClientLogin, ClientLoginFinishParameters, CredentialResponse};
use sha2::Digest as _;
use tonic::metadata::{Ascii, MetadataValue};
use tonic::service::Interceptor;
use tonic::service::interceptor::InterceptedService;
use tonic::transport::{Channel, ClientTlsConfig, Endpoint};
use tonic::{Code, Request, Status};

use crate::{ManifestParameter, ManifestParameterType, PublishArgs};

mod proto {
    pub mod users {
        tonic::include_proto!("users.v1");
    }
    pub mod admin {
        tonic::include_proto!("admin.v1");
    }
}

use proto::admin::admin_service_client::AdminServiceClient;
use proto::admin::{
    CreateIconRequest, CreateScriptRequest, ListScriptsRequest, Page, Script, ScriptContent,
    ScriptParameter, UpdateScriptRequest, script_parameter,
};
use proto::users::users_service_client::UsersServiceClient;
use proto::users::{FinishLoginRequest, LogoutRequest, StartLoginRequest, finish_login_response};

/// The name the session `publish` opens shows under in the account's
/// session list.
const DEVICE_NAME: &str = "fyde-scripts-publish";

/// The `type` every script `publish` writes has.
const SCRIPT_TYPE: &str = "scraper";

/// The most scripts `admin.v1`'s ListScripts returns per page.
const LIST_PAGE_SIZE: u32 = 100;

/// The OPAQUE ciphersuite of the fyde protocol: ristretto255 for the OPRF and
/// the key exchange, SHA-512 as the key-exchange hash (3DH), Argon2id as the
/// key-stretching function. Must match `fyde-sdk`'s (`users/crypto.rs`) and
/// the server's, or the login can't succeed.
struct FydeCipherSuite;

impl CipherSuite for FydeCipherSuite {
    type OprfCs = opaque_ke::Ristretto255;
    type KeyExchange = opaque_ke::TripleDh<opaque_ke::Ristretto255, sha2::Sha512>;
    type Ksf = Argon2<'static>;
}

/// Argon2id with `fyde-sdk`'s parameters (64 MiB, 3 iterations, 4 lanes):
/// the account's record was registered with these, so a login must stretch
/// the password exactly the same way.
fn ksf() -> Argon2<'static> {
    Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(64 * 1024, 3, 4, None).expect("hardcoded Argon2 parameters are valid"),
    )
}

/// An admin API client carrying the session's token.
type Admin = AdminServiceClient<InterceptedService<Channel, Bearer>>;

/// Adds the session's bearer token to every call.
#[derive(Clone)]
struct Bearer(MetadataValue<Ascii>);

impl Interceptor for Bearer {
    fn call(&mut self, mut request: Request<()>) -> Result<Request<()>, Status> {
        request
            .metadata_mut()
            .insert("authorization", self.0.clone());
        Ok(request)
    }
}

/// Logs into `args.server` as `args.username`, publishes every scraper, then
/// logs out whether publishing succeeded or not, so a failed run doesn't
/// leave a session open against the account's plan limit.
pub async fn publish(args: PublishArgs) -> Result<()> {
    let channel = connect(&args.server).await?;

    let token = login(
        &mut UsersServiceClient::new(channel.clone()),
        &args.username,
        &args.password,
    )
    .await
    .with_context(|| format!("logging in as {}", args.username))?;
    let bearer = Bearer(
        format!("Bearer {token}")
            .parse()
            .context("the server returned a malformed session token")?,
    );

    let mut admin = AdminServiceClient::with_interceptor(channel.clone(), bearer.clone());
    let published = publish_scripts(&mut admin).await;

    // A logout failure after a publishing failure is only logged, to keep
    // the error that actually stopped the run.
    let logged_out = UsersServiceClient::with_interceptor(channel, bearer)
        .logout(LogoutRequest {})
        .await
        .with_context(|| format!("logging out {}", args.username));
    match (published, logged_out) {
        (Ok(()), Err(err)) => Err(err),
        (Err(err), Err(logout_err)) => {
            tracing::warn!("{logout_err:#}");
            Err(err)
        }
        (published, Ok(_)) => published,
    }
}

async fn connect(url: &str) -> Result<Channel> {
    let mut endpoint =
        Endpoint::from_shared(url.to_string()).with_context(|| format!("invalid URL {url}"))?;
    if url.starts_with("https://") {
        endpoint = endpoint
            .tls_config(ClientTlsConfig::new().with_webpki_roots())
            .context("configuring TLS")?;
    }
    endpoint
        .connect()
        .await
        .with_context(|| format!("connecting to {url}"))
}

/// Runs the OPAQUE login exchange, returning the new session's token. The
/// password never leaves this process.
async fn login(
    users: &mut UsersServiceClient<Channel>,
    username: &str,
    password: &str,
) -> Result<String> {
    let start = ClientLogin::<FydeCipherSuite>::start(&mut OsRng, password.as_bytes())
        .map_err(|err| anyhow!("failed to start the OPAQUE login: {err}"))?;
    let started = users
        .start_login(StartLoginRequest {
            username: username.to_string(),
            opaque_request: start.message.serialize().to_vec(),
        })
        .await
        .context("starting the login")?
        .into_inner();

    let response = CredentialResponse::<FydeCipherSuite>::deserialize(&started.opaque_response)
        .map_err(|err| anyhow!("the server sent a malformed login response: {err}"))?;
    let ksf = ksf();
    let finished = start.state.finish(
        &mut OsRng,
        password.as_bytes(),
        response,
        ClientLoginFinishParameters::new(None, Default::default(), Some(&ksf)),
    );

    // A wrong password usually fails right here. The server's pending
    // exchange is single-use: close it with a finalization that can't
    // verify (a random MAC), as fyde-sdk does, rather than leave it behind.
    let (opaque_upload, rejected_locally) = match finished {
        Ok(result) => (result.message.serialize().to_vec(), false),
        Err(_) => {
            let mut mac = vec![0u8; sha2::Sha512::output_size()];
            OsRng.fill_bytes(&mut mac);
            (mac, true)
        }
    };

    let finished = users
        .finish_login(FinishLoginRequest {
            login_id: started.login_id,
            opaque_upload,
            device_name: DEVICE_NAME.to_string(),
            replace_session_id: String::new(),
        })
        .await;
    if rejected_locally {
        bail!("invalid username or password");
    }
    let finished = match finished {
        Ok(response) => response.into_inner(),
        Err(status) if status.code() == Code::Unauthenticated => {
            bail!("invalid username or password")
        }
        Err(status) => return Err(status).context("finishing the login"),
    };

    match finished.result {
        Some(finish_login_response::Result::Succeeded(succeeded)) => Ok(succeeded.session_token),
        Some(finish_login_response::Result::SessionLimitReached(limit)) => bail!(
            "the account already has {} open session(s), its plan's limit: log one out before \
             publishing",
            limit.max_sessions
        ),
        None => bail!("the server's login response carries no result"),
    }
}

/// Publishes every scraper through `admin`: updates the script already
/// published under the same name (whoever published it), or creates it.
async fn publish_scripts(admin: &mut Admin) -> Result<()> {
    let existing = list_scripts(admin).await.map_err(|err| {
        if err
            .downcast_ref::<Status>()
            .is_some_and(|status| status.code() == Code::PermissionDenied)
        {
            err.context("only an admin account may publish scripts")
        } else {
            err
        }
    })?;

    for scraper_name in crate::list_scraper_names()? {
        let script_dir = PathBuf::from("scrapers").join(&scraper_name);
        let script_path = script_dir.join("script.lua");
        let script = std::fs::read_to_string(&script_path)
            .with_context(|| format!("reading Lua script {}", script_path.display()))?;
        let manifest = crate::load_manifest(&script_dir, &scraper_name)?;

        let logo_path = script_dir.join("logo.png");
        let icon_id = if logo_path.is_file() {
            let logo = std::fs::read(&logo_path)
                .with_context(|| format!("reading logo {}", logo_path.display()))?;
            admin
                .create_icon(CreateIconRequest { content: logo })
                .await
                .with_context(|| format!("uploading the logo of {scraper_name}"))?
                .into_inner()
                .icon_id
        } else {
            String::new()
        };

        let content = ScriptContent {
            name: manifest.name.clone(),
            is_public: true,
            script,
            description: manifest.description,
            short_description: manifest.short_description,
            allowed_domains: manifest.allowed_domains,
            r#type: SCRIPT_TYPE.to_string(),
            parameters: manifest
                .parameters
                .into_iter()
                .map(|(key, parameter)| (key, parameter.into()))
                .collect::<HashMap<_, _>>(),
            icon_id,
        };

        match existing
            .iter()
            .find(|script| script.name == manifest.name && script.r#type == SCRIPT_TYPE)
        {
            Some(current) => {
                admin
                    .update_script(UpdateScriptRequest {
                        script_id: current.id.clone(),
                        content: Some(content),
                    })
                    .await
                    .with_context(|| format!("updating script {scraper_name}"))?;
                tracing::info!("updated {scraper_name}");
            }
            None => {
                admin
                    .create_script(CreateScriptRequest {
                        content: Some(content),
                    })
                    .await
                    .with_context(|| format!("creating script {scraper_name}"))?;
                tracing::info!("created {scraper_name}");
            }
        }
    }

    Ok(())
}

/// Every script on the server, public or not, most recently updated first,
/// so a name shared by several scripts matches the latest one.
async fn list_scripts(admin: &mut Admin) -> Result<Vec<Script>> {
    let mut scripts = Vec::new();
    loop {
        let page = admin
            .list_scripts(ListScriptsRequest {
                page: Some(Page {
                    offset: scripts.len() as u64,
                    limit: LIST_PAGE_SIZE,
                }),
            })
            .await
            .context("listing the server's scripts")?
            .into_inner();
        let listed = page.scripts.len();
        scripts.extend(page.scripts);
        if listed == 0 || scripts.len() as u64 >= page.total {
            return Ok(scripts);
        }
    }
}

impl From<ManifestParameter> for ScriptParameter {
    fn from(parameter: ManifestParameter) -> Self {
        let r#type = match parameter.parameter_type {
            ManifestParameterType::String => script_parameter::Type::String,
            ManifestParameterType::Number => script_parameter::Type::Number,
            ManifestParameterType::Boolean => script_parameter::Type::Boolean,
        };
        ScriptParameter {
            label: parameter.label,
            placeholder: parameter.placeholder,
            r#type: r#type as i32,
            required: parameter.required,
            secret: parameter.secret,
        }
    }
}
