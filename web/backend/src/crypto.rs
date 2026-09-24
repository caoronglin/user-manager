//! Web 独立 secret 管理：master key 加载/生成 + AEAD 加解密（AES-256-GCM）。
//!
//! 边界：使用 **Web 自己的 master key**（/var/lib/user-manager-web/secrets/master.key，
//! 0600），不读取 CLI/TUI 特权域主密钥。用于加密 TOTP secret 与 WeCom webhook（P4）。

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Component, Path};

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
use base64::Engine as _;
use rand::RngCore;

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 12;

/// 打开应用私有文件。拒绝符号链接、硬链接和非当前服务用户所有的文件；
/// 所有者目录必须是 0700，文件收紧为 0600。新文件用 create_new 原子创建。
pub(crate) fn open_private_file(path: &Path) -> io::Result<(File, bool)> {
    if path
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "private file path must not contain parent traversal",
        ));
    }
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    ensure_private_parent(parent)?;

    loop {
        match open_existing_private(path) {
            Ok(file) => return Ok((file, false)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => match create_private(path) {
                Ok(file) => return Ok((file, true)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            },
            Err(error) => return Err(error),
        }
    }
}

#[cfg(unix)]
fn ensure_private_parent(parent: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};

    match std::fs::symlink_metadata(parent) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new().mode(0o700).create(parent)?;
        }
        Err(error) => return Err(error),
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "private file parent must be a real directory",
            ));
        }
        Ok(_) => {}
    }

    // Open the directory itself without following a final symlink. Private state
    // directories must already be private; do not chmod an arbitrary configured
    // parent (which could be a user's home directory). A sticky shared directory
    // such as /tmp is allowed for isolated tests and explicit overrides.
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(parent)?;
    let metadata = directory.metadata()?;
    if !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "private file parent must be a directory",
        ));
    }
    let mode = metadata.permissions().mode();
    let euid = unsafe { libc::geteuid() };
    if mode & 0o022 != 0 && mode & 0o1000 != 0 {
        return Ok(());
    }
    if metadata.uid() == euid {
        if mode & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "private file parent directory must not grant group or other access",
            ));
        }
    } else if mode & 0o022 != 0 && mode & 0o1000 == 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "shared writable parent directory is not sticky",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_private_parent(parent: &Path) -> io::Result<()> {
    let metadata = std::fs::symlink_metadata(parent)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "private file parent must be a real directory",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn open_existing_private(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "private file must be a single-link regular file owned by the service user",
        ));
    }
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    if file.metadata()?.permissions().mode() & 0o777 != 0o600 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "could not secure private file permissions",
        ));
    }
    Ok(file)
}

#[cfg(not(unix))]
fn open_existing_private(path: &Path) -> io::Result<File> {
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "private file must be a regular file",
        ));
    }
    OpenOptions::new().read(true).write(true).open(path)
}

#[cfg(unix)]
fn create_private(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    if file.metadata()?.permissions().mode() & 0o777 != 0o600 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "could not set private file permissions",
        ));
    }
    Ok(file)
}

#[cfg(not(unix))]
fn create_private(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(path)
}

/// 加载 master key；不存在则用 0600 原子创建（私有父目录 0700）。
pub fn load_or_create_master_key(path: &Path) -> io::Result<[u8; KEY_LEN]> {
    let (mut file, created) = open_private_file(path)?;
    if created {
        let mut key = [0u8; KEY_LEN];
        rand::rngs::OsRng.fill_bytes(&mut key);
        file.write_all(&key)?;
        file.sync_all()?;
        return Ok(key);
    }

    let mut existing = Vec::with_capacity(KEY_LEN + 1);
    file.take((KEY_LEN + 1) as u64).read_to_end(&mut existing)?;
    if existing.len() != KEY_LEN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "master key has wrong length",
        ));
    }
    let mut key = [0u8; KEY_LEN];
    key.copy_from_slice(&existing);
    Ok(key)
}

/// 加密：随机 12B nonce || ciphertext，base64 编码返回。失败返回 None。
pub fn encrypt(key: &[u8; KEY_LEN], plaintext: &[u8]) -> Option<String> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let mut nonce = [0u8; NONCE_LEN];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let ct = cipher.encrypt(Nonce::from_slice(&nonce), plaintext).ok()?;
    let mut out = nonce.to_vec();
    out.extend_from_slice(&ct);
    Some(base64::engine::general_purpose::STANDARD.encode(out))
}

/// 解密 base64(nonce||ct)。失败返回 None。
pub fn decrypt(key: &[u8; KEY_LEN], blob: &str) -> Option<Vec<u8>> {
    let data = base64::engine::general_purpose::STANDARD
        .decode(blob.as_bytes())
        .ok()?;
    if data.len() <= NONCE_LEN {
        return None;
    }
    let (n, ct) = data.split_at(NONCE_LEN);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher.decrypt(Nonce::from_slice(n), ct).ok()
}

pub fn encrypt_str(key: &[u8; KEY_LEN], s: &str) -> Option<String> {
    encrypt(key, s.as_bytes())
}

pub fn decrypt_str(key: &[u8; KEY_LEN], blob: &str) -> Option<String> {
    decrypt(key, blob).and_then(|b| String::from_utf8(b).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn private_temp_dir() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "umweb-crypto-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&path).expect("create temp dir");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        path
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let key = [7u8; KEY_LEN];
        let ct = encrypt_str(&key, "super-secret-totp").unwrap();
        assert_ne!(ct, "super-secret-totp");
        assert_eq!(decrypt_str(&key, &ct).unwrap(), "super-secret-totp");
    }

    #[test]
    fn tamper_detected() {
        let key = [7u8; KEY_LEN];
        let ct = encrypt_str(&key, "hello").unwrap();
        // 翻转一个 base64 字符（改内容）。
        let mut chars: Vec<char> = ct.chars().collect();
        if let Some(c) = chars.last_mut() {
            *c = if *c == 'A' { 'B' } else { 'A' };
        }
        let tampered: String = chars.into_iter().collect();
        assert!(
            decrypt_str(&key, &tampered).is_none()
                || decrypt_str(&key, &tampered) != Some("hello".to_string())
        );
    }

    #[cfg(unix)]
    #[test]
    fn master_key_is_created_private_and_reused() {
        use std::os::unix::fs::PermissionsExt;

        let dir = private_temp_dir();
        let path = dir.join("secrets").join("master.key");
        let first = load_or_create_master_key(&path).expect("create key");
        let metadata = std::fs::metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(
            std::fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(load_or_create_master_key(&path).unwrap(), first);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn master_key_rejects_symlinks_and_hardlinks() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let dir = private_temp_dir();
        let target = dir.join("target");
        std::fs::write(&target, [9u8; KEY_LEN]).unwrap();
        let symlink_path = dir.join("symlink.key");
        symlink(&target, &symlink_path).unwrap();
        assert!(load_or_create_master_key(&symlink_path).is_err());

        let symlink_dir = dir.join("linked-directory");
        symlink(&dir, &symlink_dir).unwrap();
        assert!(load_or_create_master_key(&symlink_dir.join("other.key")).is_err());

        let hardlink_path = dir.join("hardlink.key");
        std::fs::hard_link(&target, &hardlink_path).unwrap();
        assert!(load_or_create_master_key(&target).is_err());

        // A regular owner-controlled key with broad mode is repaired before use.
        std::fs::remove_file(&hardlink_path).unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(load_or_create_master_key(&target).unwrap(), [9u8; KEY_LEN]);
        assert_eq!(
            std::fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn private_files_refuse_shared_owned_parent_directories() {
        use std::os::unix::fs::PermissionsExt;

        let dir = private_temp_dir();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = dir.join("master.key");
        assert!(load_or_create_master_key(&path).is_err());
        assert_eq!(
            std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o755
        );

        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(load_or_create_master_key(&path).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn private_files_allow_sticky_shared_temp_parent() {
        use std::os::unix::fs::PermissionsExt;

        let path = std::env::temp_dir().join(format!(
            "umweb-crypto-shared-{}-{}.key",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let (file, created) =
            open_private_file(&path).expect("open private file in sticky temp dir");
        assert!(created);
        assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);
        drop(file);
        std::fs::remove_file(path).unwrap();
    }
}
