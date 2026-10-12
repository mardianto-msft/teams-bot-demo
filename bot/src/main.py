import asyncio
import hashlib
import hmac
import logging
import os

import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from microsoft_teams.api import InstalledActivity, MessageActivity, MessageActivityInput
from microsoft_teams.apps import ActivityContext, App, FastAPIAdapter

from cards import build_issue_card
from store import create_store

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ticket-bot")

HANDLED_ACTIONS = {"opened", "edited", "closed", "reopened"}

server = FastAPI(title="GitHub issues -> Teams bot")
app = App(http_server_adapter=FastAPIAdapter(app=server))
store = create_store()
conversations: dict[str, str] = {}
lock = asyncio.Lock()


async def remember(conversation_id: str, service_url: str | None) -> None:
    async with lock:
        if conversations.get(conversation_id) != (service_url or ""):
            conversations[conversation_id] = service_url or ""
            await store.save(conversations)


@app.on_install_add
async def on_install(ctx: ActivityContext[InstalledActivity]) -> None:
    await remember(ctx.activity.conversation.id, ctx.activity.service_url)
    await ctx.send("Hi! I'll post GitHub issue notifications in this conversation.")


@app.on_message
async def on_message(ctx: ActivityContext[MessageActivity]) -> None:
    # Mentioning the bot in a channel (re)registers it for notifications.
    await remember(ctx.activity.conversation.id, ctx.activity.service_url)
    await ctx.send("Notifications for GitHub issues will be posted here.")


def verify_signature(secret: str, body: bytes, signature: str | None) -> bool:
    if not signature or not signature.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


@server.get("/health")
async def health() -> dict[str, str]:
    return {"status": "healthy"}


@server.post("/api/github/webhook")
async def github_webhook(request: Request) -> dict[str, object]:
    secret = os.getenv("GITHUB_WEBHOOK_SECRET")
    if not secret:
        raise HTTPException(status_code=500, detail="Webhook secret not configured")

    body = await request.body()
    if not verify_signature(secret, body, request.headers.get("X-Hub-Signature-256")):
        raise HTTPException(status_code=401, detail="Invalid signature")

    event = request.headers.get("X-GitHub-Event")
    if event == "ping":
        return {"ok": True}
    if event != "issues":
        return {"ok": True, "ignored": event}

    payload = await request.json()
    action = payload.get("action")
    if action not in HANDLED_ACTIONS:
        return {"ok": True, "ignored": action}

    card = build_issue_card(
        action,
        payload["issue"],
        payload["repository"]["full_name"],
        payload["sender"]["login"],
    )

    async with lock:
        targets = dict(conversations)
    if not targets:
        logger.warning("No Teams conversation registered; install the bot in a channel first")
        return {"ok": True, "delivered": 0}

    delivered = 0
    for conversation_id, service_url in targets.items():
        try:
            await app.send(conversation_id, MessageActivityInput().add_card(card), service_url=service_url or None)
            delivered += 1
        except Exception:
            logger.exception("Failed to send to %s", conversation_id)
    return {"ok": True, "delivered": delivered}


async def serve() -> None:
    conversations.update(await store.load())
    await app.initialize()
    port = int(os.getenv("PORT", "3978"))
    await uvicorn.Server(uvicorn.Config(server, host="0.0.0.0", port=port)).serve()


def main() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main()
