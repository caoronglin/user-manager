# D — 密钥与机密存储守卫消融

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | rl_mail_queue 机密字段 HMAC-SHA256 完整性校验（encrypt-then-MAC） | `lib/rl_mail_queue.sh:243` | GUARD-ACTIVE | `ab_sub` 把 `[[ "$rl_mac_calc" == "$rl_mac_expected" ]] || exit 1` 换成恒真 `:`。**保留**：base64 解码、IV 长度/hex 正则（`:240`）、MAC hex 正则（`:242`）、`openssl enc -d` 解密（`:246`）、先认证后解密的顺序 | `bash .validation/ablation-2026-10-02/harness/D1-mail-hmac.sh` | 未篡改：两侧均 `intact_rc=0` 且还原 `SMTP_PASSWORD_TOP_SECRET`（解密能力完好）。篡改首块 ciphertext 1 字节、保留原 MAC：baseline `tamper_rc=1 ACCEPTED_TAMPER=no`（`rl_mail_secret_decrypt` 在 `:243` exit 1，明文为空）；消融 `tamper_rc=0 ACCEPTED_TAMPER=yes` 并输出 `tamper_plaintext=\x14A9…_SECRET`，即**篡改密文被当作合法明文接受** | `harness/D1-mail-hmac.sh`、`logs/D1-mail-hmac.txt` |

## 有效判据自检

| 场景 | 自检1 baseline 拒绝理由指向守卫 | 自检2 ablated 真实走通 | 自检3 无 127/函数缺失 |
| --- | --- | --- | --- |
| D1 | 是（唯一非零退出点是 `:243` 的 MAC 比对，其余校验全在同链且未被改动） | 是（rc=0 + 篡改密文被解出并回显，证明解密能力未被拆掉） | 是（两侧 rc 分别为 1/0，均非 127） |

## 攻击面选择：为什么翻第一块字节

消融只删比对、不删能力，攻击必须落在**只有 HMAC 能挡、padding 校验挡不住**的位置。

AES-256-CBC 下翻转第 0 块密文的第 0 字节，只污染第 0/1 块明文，末块 padding 完好，openssl 解密会成功并产出可预测的垃圾明文。若改翻末块，padding 大概率报错，`openssl enc -d` 自身就会失败，消融与否都拒绝，实验将退化为「无差异」而失效。

实测输出印证了这一点：消融侧返回的明文尾部仍是可辨认的 `_SECRET`，头部是乱码——正是 CBC 首块污染的典型形态。

## 纵深与顺序保证

`:245` 的注释写明「Authenticate the ciphertext before decrypting it」，代码顺序也确实如此（`:241-243` 全部认证 → `:246` 才 `openssl enc -d`）。这意味着即便 HMAC 被消融，本守卫的完整性保证归零，而其余结构校验（IV 长度、hex 格式、base64 解码）只防「畸形输入」，不防「恶意构造」——它们无法替代 MAC。

D1 的判定不依赖「消融后能否造成更大影响」，只依赖一条可证伪的事实：同一段篡改密文，baseline 拒绝、消融接受。

## 备注

- 探针使用固定 DEK `0123…ef`，明文 `SMTP_PASSWORD_TOP_SECRET`，不触碰任何真实密钥文件。
- 消融树为 `.validation/ablation-2026-10-02/work/D1-ablated`，由 `cp -al` 硬链接自一次性基线树 `work/_baseline`，生产 `lib/rl_mail_queue.sh` 零写入。
- 两次运行的 IV 不同（随机 IV 生效），不影响判据：比较的是「同一密文在两侧的行为」，篡改构造在各自树内独立完成。
