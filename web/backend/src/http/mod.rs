//! HTTP 层：路由组装、统一响应信封、中间件。

pub mod audit_api;
pub mod logs_api;
pub mod middleware;
pub mod read_api;
pub mod reports_api;
pub mod response;
pub mod routes;

pub use routes::build_router;
