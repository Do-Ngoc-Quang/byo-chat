-- Schema metadata (thiet-ke-chinh.md mục 13). Mọi khóa chính đặt account_id hoặc conv_id làm cột đầu
-- để sau này chuyển sang Citus/CockroachDB mà không đổi schema. ID là UUID (UUIDv7 do ứng dụng sinh).

CREATE TABLE accounts (
    account_id    uuid PRIMARY KEY,
    contact_hash  bytea NOT NULL UNIQUE,            -- băm số điện thoại hoặc email
    settings      jsonb NOT NULL DEFAULT '{}',
    identity_key  bytea,                            -- khóa danh tính công khai hiện tại (Ed25519)
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    account_id    uuid NOT NULL REFERENCES accounts,
    device_id     uuid NOT NULL UNIQUE,
    platform      smallint NOT NULL,                -- chat.v1.Platform
    device_name   text NOT NULL DEFAULT '',
    push_token    text,
    public_key    bytea NOT NULL,                   -- khóa ký Ed25519 của thiết bị
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz,
    revoked_at    timestamptz,
    PRIMARY KEY (account_id, device_id)
);

CREATE TABLE key_packages (
    device_id     uuid NOT NULL,
    kp_id         uuid NOT NULL,
    blob          bytea NOT NULL,
    last_resort   boolean NOT NULL DEFAULT false,
    expires_at    timestamptz NOT NULL,
    PRIMARY KEY (device_id, kp_id)
);
CREATE INDEX key_packages_expiry ON key_packages (expires_at);

CREATE TABLE conversations (
    conv_id       uuid PRIMARY KEY,
    kind          smallint NOT NULL,                -- chat.v1.ConvKind
    mls_group_id  bytea NOT NULL UNIQUE,            -- 32 byte, một-một với conv_id
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Hội thoại 1-1: mỗi cặp tài khoản chỉ có một.
CREATE TABLE direct_pairs (
    account_lo    uuid NOT NULL,
    account_hi    uuid NOT NULL,
    conv_id       uuid NOT NULL REFERENCES conversations,
    PRIMARY KEY (account_lo, account_hi),
    CHECK (account_lo < account_hi)
);

CREATE TABLE members_by_conv (
    conv_id       uuid NOT NULL REFERENCES conversations,
    account_id    uuid NOT NULL,
    role          smallint NOT NULL,                -- chat.v1.Role
    leaving       boolean NOT NULL DEFAULT false,   -- đang rời (giao-thuc.md 6.4)
    joined_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (conv_id, account_id)
);

CREATE TABLE convs_by_account (
    account_id    uuid NOT NULL,
    conv_id       uuid NOT NULL REFERENCES conversations,
    last_activity timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, conv_id)
);
CREATE INDEX convs_by_account_recent ON convs_by_account (account_id, last_activity DESC);

CREATE TABLE group_info (
    conv_id       uuid PRIMARY KEY REFERENCES conversations,
    epoch         bigint NOT NULL,
    blob          bytea NOT NULL                    -- MlsMessage chứa GroupInfo, dùng cho External Commit
);

CREATE TABLE calls (
    call_id       uuid PRIMARY KEY,
    conv_id       uuid NOT NULL,
    caller        uuid NOT NULL,
    kind          smallint NOT NULL,
    started_at    timestamptz NOT NULL,
    ended_at      timestamptz,
    result        text
);

CREATE TABLE media (
    media_id      uuid PRIMARY KEY,
    owner         uuid NOT NULL,
    size_bytes    bigint NOT NULL,
    object_key    text NOT NULL,
    is_public     boolean NOT NULL DEFAULT false,
    expires_at    timestamptz
);

CREATE TABLE backups (
    account_id    uuid NOT NULL,
    object_key    text NOT NULL,
    size_bytes    bigint NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, created_at)
);

-- Liên kết thiết bị mới (giao-thuc.md 6.5). Hạn 5 phút; dọn bằng expires_at.
CREATE TABLE device_links (
    link_id           uuid PRIMARY KEY,
    short_code        text NOT NULL,
    platform          smallint NOT NULL,
    device_name       text NOT NULL DEFAULT '',
    device_public_key bytea NOT NULL,
    ephemeral_pubkey  bytea NOT NULL,               -- khóa X25519 tạm của thiết bị mới
    account_id        uuid,                         -- điền khi thiết bị cũ ApproveLink
    credential        bytea,                        -- credential do thiết bị cũ ký
    sealed_bundle     bytea,
    expires_at        timestamptz NOT NULL
);
CREATE INDEX device_links_expiry ON device_links (expires_at);

-- Bản xác nhận thu hồi (giao-thuc.md 6.6): chỉ thêm, không sửa; client lấy qua KeyService.
CREATE TABLE revocations (
    account_id    uuid NOT NULL,
    device_id     uuid NOT NULL,
    statement     bytea NOT NULL,                   -- ký bằng khóa danh tính tài khoản
    revoked_at    timestamptz NOT NULL,
    PRIMARY KEY (account_id, device_id)
);
