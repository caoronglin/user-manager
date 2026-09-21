//! HTTP 层：路由组装、统一响应信封、中间件。

pub mod middleware;
pub mod response;
pub mod routes;

pub use routes::build_router;
