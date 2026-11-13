// Test-only gRPC tokenizer over OpenSSL with a configurable TLS policy. It runs under the
// default provider so that it can offer what a FIPS client must refuse.
use foreign_types::ForeignTypeRef;
use openssl::ssl::{Ssl, SslAcceptor, SslFiletype, SslMethod, SslVerifyMode, SslVersion};
use std::{env, io, pin::Pin, sync::atomic::{AtomicU64, Ordering}, task::{Context, Poll}};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpListener;
use tokio_openssl::SslStream;
use tonic::{transport::{server::Connected, Server}, Request, Response, Status};

pub mod pb {
    #![allow(dead_code)]
    include!(env!("TT_GEN"));
}
mod srv { include!(concat!(env!("OUT_DIR"), "/milvus.proto.tokenizer.Tokenizer.rs")); }

static CALLS: AtomicU64 = AtomicU64::new(0);
struct T;
#[tonic::async_trait]
impl srv::tokenizer_server::Tokenizer for T {
    async fn tokenize(&self, r: Request<pb::TokenizationRequest>) -> Result<Response<pb::TokenizationResponse>, Status> {
        let n = CALLS.fetch_add(1, Ordering::SeqCst) + 1;
        let text = r.into_inner().text;
        println!("SERVER CALL n={n} text={text:?}");
        let tokens = text.split_whitespace().enumerate().map(|(i, t)| pb::Token {
            text: format!("srv:{t}"), offset_from: 0, offset_to: t.len() as i32, position: i as i32, position_length: 1,
        }).collect();
        Ok(Response::new(pb::TokenizationResponse { tokens }))
    }
}
struct Tls(SslStream<tokio::net::TcpStream>);
impl Connected for Tls { type ConnectInfo = (); fn connect_info(&self) {} }
impl AsyncRead for Tls { fn poll_read(mut self: Pin<&mut Self>, c: &mut Context<'_>, b: &mut ReadBuf<'_>) -> Poll<io::Result<()>> { Pin::new(&mut self.0).poll_read(c, b) } }
impl AsyncWrite for Tls {
    fn poll_write(mut self: Pin<&mut Self>, c: &mut Context<'_>, b: &[u8]) -> Poll<io::Result<usize>> { Pin::new(&mut self.0).poll_write(c, b) }
    fn poll_flush(mut self: Pin<&mut Self>, c: &mut Context<'_>) -> Poll<io::Result<()>> { Pin::new(&mut self.0).poll_flush(c) }
    fn poll_shutdown(mut self: Pin<&mut Self>, c: &mut Context<'_>) -> Poll<io::Result<()>> { Pin::new(&mut self.0).poll_shutdown(c) }
}
fn arg(n: &str) -> Option<String> { let a: Vec<String> = env::args().collect(); a.iter().position(|x| x == n).and_then(|i| a.get(i + 1).cloned()) }
fn ver(s: &str) -> SslVersion { match s { "1.2" => SslVersion::TLS1_2, "1.3" => SslVersion::TLS1_3, "1.1" => SslVersion::TLS1_1, _ => panic!("ver") } }
fn group_name(ssl: &openssl::ssl::SslRef) -> String {
    unsafe {
        let g = openssl_sys::SSL_ctrl(ssl.as_ptr(), 134, 0, std::ptr::null_mut()) as libc::c_int; // SSL_get_negotiated_group
        match g { 415 => "P-256", 715 => "P-384", 716 => "P-521", 1034 => "X25519", 1035 => "X448", _ => "other" }.to_string() + &format!("({g:#x})")
    }
}
#[tokio::main]
async fn main() {
    if arg("--plain").is_some() {
        println!("SERVER READY plain");
        Server::builder().add_service(srv::tokenizer_server::TokenizerServer::new(T)).serve(arg("--addr").unwrap().parse().unwrap()).await.unwrap();
        return;
    }
    let mut b = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls_server()).unwrap();
    b.set_certificate_chain_file(arg("--cert").unwrap()).unwrap();
    b.set_private_key_file(arg("--key").unwrap(), SslFiletype::PEM).unwrap();
    if let Some(v) = arg("--min") { b.set_min_proto_version(Some(ver(&v))).unwrap(); }
    if let Some(v) = arg("--max") { b.set_max_proto_version(Some(ver(&v))).unwrap(); }
    if let Some(c) = arg("--tls13") { b.set_ciphersuites(&c).unwrap(); }
    if let Some(c) = arg("--tls12") { b.set_cipher_list(&c).unwrap(); }
    if let Some(g) = arg("--groups") { b.set_groups_list(&g).unwrap(); }
    if let Some(ca) = arg("--client-ca") {
        b.set_ca_file(&ca).unwrap();
        b.set_verify(SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT);
    }
    if arg("--alpn").as_deref() != Some("none") {
        b.set_alpn_select_callback(|_, p| openssl::ssl::select_next_proto(b"\x02h2", p).ok_or(openssl::ssl::AlpnError::NOACK));
    }
    let acc = b.build();
    let l = TcpListener::bind(arg("--addr").unwrap()).await.unwrap();
    let inc = async_stream(l, acc);
    println!("SERVER READY {} {}", openssl::version::version(), arg("--addr").unwrap());
    Server::builder().add_service(srv::tokenizer_server::TokenizerServer::new(T)).serve_with_incoming(inc).await.unwrap();
}
fn async_stream(l: TcpListener, acc: SslAcceptor) -> impl futures::Stream<Item = Result<Tls, io::Error>> {
    let (tx, rx) = futures::channel::mpsc::unbounded();
    tokio::spawn(async move { loop {
        let (s, _) = l.accept().await.unwrap();
        let (tx, acc) = (tx.clone(), acc.clone());
        tokio::spawn(async move {
            let mut st = SslStream::new(Ssl::new(acc.context()).unwrap(), s).unwrap();
            match Pin::new(&mut st).accept().await {
                Ok(()) => {
                    let ssl = st.ssl();
                    println!("SERVER HANDSHAKE ok version={} cipher={} group={} alpn={:?} client_cert={:?}", ssl.version_str(),
                        ssl.current_cipher().map(|c| c.name()).unwrap_or("?"), group_name(ssl),
                        ssl.selected_alpn_protocol().map(|p| String::from_utf8_lossy(p).to_string()),
                        ssl.peer_certificate().map(|c| format!("{:?}", c.subject_name().entries().next().map(|e| e.data().as_utf8().unwrap().to_string()))));
                    let _ = tx.unbounded_send(Ok(Tls(st)));
                }
                Err(e) => println!("SERVER HANDSHAKE failed: {e}"),
            }
        });
    }});
    rx
}
