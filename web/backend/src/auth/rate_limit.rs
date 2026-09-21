//! 登录/接口限流：IP + username 双维度，指数退避，防撞库与用户枚举。
//!
//! P1 用进程内滑动窗口；多实例部署可替换为共享存储。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Clone)]
struct Bucket {
    hits: u32,
    window_start: Instant,
    blocked_until: Option<Instant>,
}

pub struct RateLimiter {
    inner: Mutex<HashMap<String, Bucket>>,
    max_hits: u32,
    window: Duration,
    base_backoff: Duration,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            max_hits: 5,
            window: Duration::from_secs(60),
            base_backoff: Duration::from_secs(1),
        }
    }

    /// 记录一次命中；若已达阈值则进入指数退避并返回需要等待的秒数。
    pub fn hit(&self, key: &str) -> Result<(), u64> {
        let now = Instant::now();
        let mut guard = self.inner.lock().expect("rate limiter poisoned");
        let entry = guard.entry(key.to_string()).or_insert(Bucket {
            hits: 0,
            window_start: now,
            blocked_until: None,
        });

        if let Some(until) = entry.blocked_until {
            if until > now {
                return Err((until - now).as_secs().max(1));
            }
            // 退避结束，重置窗口。
            entry.blocked_until = None;
            entry.hits = 0;
            entry.window_start = now;
        }

        if now.duration_since(entry.window_start) > self.window {
            entry.hits = 0;
            entry.window_start = now;
        }

        entry.hits += 1;
        if entry.hits > self.max_hits {
            // 指数退避：按已超出的次数翻倍，设上限。
            let over = entry.hits - self.max_hits;
            let backoff = self.base_backoff * 2u32.pow(over.min(6));
            entry.blocked_until = Some(now + backoff);
            return Err(backoff.as_secs().max(1));
        }
        Ok(())
    }
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new()
    }
}
