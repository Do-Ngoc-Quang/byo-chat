// Sinh Rust từ proto/ vào OUT_DIR (không commit mã sinh).
fn main() {
    let proto_root = "../../../proto";
    let files = ["common", "ws", "services", "payload"].map(|f| format!("{proto_root}/chat/v1/{f}.proto"));
    std::env::set_var("PROTOC", protoc_bin_vendored::protoc_bin_path().unwrap());
    prost_build::compile_protos(&files, &[proto_root]).unwrap();
    println!("cargo:rerun-if-changed={proto_root}");
}
