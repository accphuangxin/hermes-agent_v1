"""Doubao (ByteDance Volcengine) provider profile."""

from providers import register_provider
from providers.base import ProviderProfile

doubao = ProviderProfile(
    name="doubao",
    aliases=("volcengine", "bytedance", "ark"),
    env_vars=("DOUBAO_API_KEY", "ARK_API_KEY", "VOLCENGINE_API_KEY"),
    display_name="Doubao (Volcengine)",
    description="Doubao — ByteDance Volcengine Ark models (豆包)",
    signup_url="https://console.volcengine.com/ark",
    fallback_models=(
        "doubao-seed-2.0-code",
        "doubao-1.5-pro-256k",
        "doubao-1.5-pro-32k",
        "doubao-pro-256k",
        "doubao-pro-32k",
        "doubao-lite-32k",
    ),
    base_url="https://ark.cn-beijing.volces.com/api/v3",
)

register_provider(doubao)
