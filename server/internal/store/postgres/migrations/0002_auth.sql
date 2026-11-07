-- AuthService, RegisterDevice, KeyService (giao-thuc.md 6.1, ADR 0007). Chỉ lưu băm của OTP, ticket, refresh token.

ALTER TABLE devices ADD COLUMN credential bytea;  -- 136 byte, xem giao-thuc.md 6.1; null với thiết bị do công cụ dev thêm

CREATE TABLE otp_challenges (
    challenge_id  uuid PRIMARY KEY,
    contact_hash  bytea NOT NULL,
    code_hash     bytea NOT NULL,
    attempts      int NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL,
    expires_at    timestamptz NOT NULL
);
CREATE INDEX otp_challenges_contact ON otp_challenges (contact_hash, created_at DESC);
CREATE INDEX otp_challenges_expiry ON otp_challenges (expires_at);

CREATE TABLE session_tickets (
    ticket_hash   bytea PRIMARY KEY,
    account_id    uuid NOT NULL REFERENCES accounts,
    is_new        boolean NOT NULL,
    expires_at    timestamptz NOT NULL,
    used_at       timestamptz
);
CREATE INDEX session_tickets_expiry ON session_tickets (expires_at);

CREATE TABLE refresh_tokens (
    token_hash    bytea PRIMARY KEY,
    device_id     uuid NOT NULL,
    expires_at    timestamptz NOT NULL
);
CREATE INDEX refresh_tokens_device ON refresh_tokens (device_id);
