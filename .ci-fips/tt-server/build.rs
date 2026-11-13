fn main() {
    let svc = tonic_build::manual::Service::builder()
        .name("Tokenizer").package("milvus.proto.tokenizer")
        .method(tonic_build::manual::Method::builder().name("tokenize").route_name("Tokenize")
            .input_type("crate::pb::TokenizationRequest").output_type("crate::pb::TokenizationResponse")
            .codec_path("tonic::codec::ProstCodec").build())
        .build();
    tonic_build::manual::Builder::new().build_client(false).compile(&[svc]);
}
