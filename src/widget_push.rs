//! Widget-only refresh jobs. Never serialize/debug their private APNs token.
pub const MAX_WIDGET_ATTEMPTS: i64 = 6;
pub const WIDGET_COALESCE_SECONDS: i64 = 2;
pub const WIDGET_MIN_INTERVAL_SECONDS: i64 = 5;
#[derive(Clone)]
pub struct WidgetJob {
    pub device_id: String,
    pub token: String,
    pub environment: String,
    pub token_version: i64,
    pub generation: i64,
    pub attempts: i64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WidgetFailure {
    Transport,
    CredentialsUnavailable,
    RateLimited,
    ServerError,
    BadDeviceToken,
    BadTopic,
    TopicDisallowed,
    DeviceTokenNotForTopic,
    InvalidProviderToken,
    ExpiredProviderToken,
    Forbidden,
    Rejected,
    Unregistered,
}
impl WidgetFailure {
    pub fn code(self) -> &'static str {
        match self {
            Self::Transport => "transport",
            Self::CredentialsUnavailable => "credentials_unavailable",
            Self::RateLimited => "rate_limited",
            Self::ServerError => "server_error",
            Self::BadDeviceToken => "bad_device_token",
            Self::BadTopic => "bad_topic",
            Self::TopicDisallowed => "topic_disallowed",
            Self::DeviceTokenNotForTopic => "device_token_not_for_topic",
            Self::InvalidProviderToken => "invalid_provider_token",
            Self::ExpiredProviderToken => "expired_provider_token",
            Self::Forbidden => "forbidden",
            Self::Rejected => "request_rejected",
            Self::Unregistered => "device_unregistered",
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WidgetDelivery {
    Delivered,
    Retry(WidgetFailure),
    Rejected(WidgetFailure),
    Unregistered,
}
