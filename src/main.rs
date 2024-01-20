use bytes::BytesMut;
use quinn::{Endpoint, ServerConfig};
use std::str;
use std::{net::SocketAddr, sync::Arc};

pub const ALPN_QUIC_HTTP: &[&[u8]] = &[b"demo"];

#[tokio::main]
async fn main() {
    // Set up the tracing subscriber
    tracing::subscriber::set_global_default(
        tracing_subscriber::FmtSubscriber::builder()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .finish(),
    )
    .unwrap();

    let addr = "127.0.0.1:4567".parse().unwrap();
    run_server(addr).await;
}

async fn run_server(addr: SocketAddr) {
    let cert = rcgen::generate_simple_self_signed(vec![
        "127.0.0.1".into(),
        "localhost".into(),
        "0.0.0.0".into(),
    ])
    .unwrap();
    let cert_der = cert.serialize_der().unwrap();
    let private_key = cert.serialize_private_key_der();
    let private_key = rustls::PrivateKey(private_key);
    let cert_chain = vec![rustls::Certificate(cert_der.clone())];

    let mut server_crypto = rustls::ServerConfig::builder()
        .with_safe_defaults()
        .with_no_client_auth()
        .with_single_cert(cert_chain, private_key)
        .unwrap();
    server_crypto.alpn_protocols = ALPN_QUIC_HTTP.iter().map(|&x| x.into()).collect();

    let server_config = ServerConfig::with_crypto(Arc::new(server_crypto));
    let endpoint = Endpoint::server(server_config, addr).unwrap();

    let incoming = endpoint.accept().await.unwrap();
    let conn = incoming.await.unwrap();
    println!(
        "[server] connection accepted: addr={}",
        conn.remote_address()
    );

    // (A) **********************************************************************************************************************************
    println!("waiting for bi stream");
    let (_send, mut recv) = conn.accept_bi().await.unwrap();
    // Uncomment this line and we accept the stream we create once the NWGroupConnection is ready.
    // let (mut send, mut recv) = conn.accept_bi().await.unwrap();

    println!("reading from recv");

    // let mut header_bytes = bytes::BytesMut::zeroed(8);
    let mut header_bytes = [0u8; 8];

    // ***************************************************************************************************************************************************************
    // (B) If we only accept the first stream we never get data because in the Swift code, we never
    // have a handle to the stream.
    if let Err(err) = recv.read_exact(&mut header_bytes).await {
        println!("error reading header: {:?}", err);
        return;
    }

    println!("read bytes {:?}", header_bytes.len());
    let version = header_bytes[0];
    let message_type = header_bytes[1];
    let length = u32::from_be_bytes(header_bytes[2..6].try_into().unwrap());

    println!(
        "version: {:?}, message_type: {:?}, length: {:?}",
        version, message_type, length
    );

    // Read the body
    let mut body_bytes = BytesMut::zeroed(length as usize);
    recv.read(&mut body_bytes).await.unwrap();

    // Convert BytesMut to a &str, handling potential UTF-8 errors
    match str::from_utf8(&body_bytes) {
        Ok(s) => println!("String: {}", s),
        Err(e) => println!("Error decoding UTF-8: {}", e),
    }
}

// Implementation of `ServerCertVerifier` that verifies everything as trustworthy.
struct SkipServerVerification;

impl SkipServerVerification {
    fn new() -> Arc<Self> {
        Arc::new(Self)
    }
}

impl rustls::client::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::Certificate,
        _intermediates: &[rustls::Certificate],
        _server_name: &rustls::ServerName,
        _scts: &mut dyn Iterator<Item = &[u8]>,
        _ocsp_response: &[u8],
        _now: std::time::SystemTime,
    ) -> Result<rustls::client::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::ServerCertVerified::assertion())
    }
}
fn configure_client() -> quinn::ClientConfig {
    let crypto = rustls::ClientConfig::builder()
        .with_safe_defaults()
        .with_custom_certificate_verifier(SkipServerVerification::new())
        .with_no_client_auth();

    quinn::ClientConfig::new(Arc::new(crypto))
}
