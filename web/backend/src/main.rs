//! umweb 二进制入口。逻辑见 lib crate（便于集成测试）。

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    umweb::run().await
}
