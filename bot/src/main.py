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

from cards import build_comment_card, build_issue_card
from store import create_store

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ticket-bot")

# "issues" webhook actions that produce a card. Others (labeled, assigned, ...) are ignored.
HANDLED_ACTIONS = {"opened", "edited", "closed", "reopened"}

server = FastAPI(title="GitHub issues -> Teams bot")
app = App(http_server_adapter=FastAPIAdapter(app=server))
store = create_store()
# Teams conversation id -> service url for every channel that receives notifications; persisted in Blob Storage.
conversations: dict[str, str] = {}
# Guards `conversations` and the store write.
lock = asyncio.Lock()


def is_channel(conversation_id: str) -> bool:
    # Channel conversation ids end in @thread.tacv2; personal and group chats do not.
    return conversation_id.split(";")[0].endswith("@thread.tacv2")


async def remember(conversation_id: str, service_url: str | None) -> None:
    # Personal and group chats are never registered, so they never receive cards.
    if not is_channel(conversation_id):
        return
    async with lock:
        if conversations.get(conversation_id) != (service_url or ""):
            conversations[conversation_id] = service_url or ""
            await store.save(conversations)


@app.on_install_add
async def on_install(ctx: ActivityContext[InstalledActivity]) -> None:
    if not is_channel(ctx.activity.conversation.id):
        return
    await remember(ctx.activity.conversation.id, ctx.activity.service_url)
    await ctx.send("Hi! I'll post GitHub issue notifications in this conversation.")


@app.on_message
async def on_message(ctx: ActivityContext[MessageActivity]) -> None:
    # Mentioning the bot in a channel (re)registers it for notifications.
    if not is_channel(ctx.activity.conversation.id):
        await ctx.send("I only post notifications in team channels. Add me to a channel to get started.")
        return
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
    # Secret comes from Key Vault via a Container Apps secret reference (see infra/resources.bicep).
    secret = os.getenv("GITHUB_WEBHOOK_SECRET")
    if not secret:
        raise HTTPException(status_code=500, detail="Webhook secret not configured")

    # Verify against the raw bytes: GitHub signs the exact request body with HMAC-SHA256.
    body = await request.body()
    if not verify_signature(secret, body, request.headers.get("X-Hub-Signature-256")):
        raise HTTPException(status_code=401, detail="Invalid signature")

    # GitHub sends every subscribed event type to this one URL; the event name is in this header.
    event = request.headers.get("X-GitHub-Event")
    if event == "ping":
        return {"ok": True}
    # Events enabled on the webhook but not handled here (e.g. issue_dependencies) get a 200 so GitHub does not retry.
    if event not in ("issues", "issue_comment"):
        return {"ok": True, "ignored": event}

    payload = await request.json()
    action = payload.get("action")
    repo_name = payload["repository"]["full_name"]

    if event == "issue_comment":
        # GitHub also sends `issue_comment` for comments on pull requests, because a PR is an issue underneath.
        # Those payloads carry a "pull_request" key inside "issue", which is how we tell them apart.
        # To also notify on PR comments, drop that check. Edited/deleted comments are ignored; only "created" notifies.
        if action != "created" or "pull_request" in payload["issue"]:
            return {"ok": True, "ignored": action}
        card = build_comment_card(payload["comment"], payload["issue"], repo_name)
    else:
        if action not in HANDLED_ACTIONS:
            return {"ok": True, "ignored": action}
        card = build_issue_card(action, payload["issue"], repo_name, payload["sender"]["login"])

    # Copy under the lock so sends below do not hold it.
    async with lock:
        targets = dict(conversations)
    if not targets:
        logger.warning("No Teams conversation registered; install the bot in a channel first")
        return {"ok": True, "delivered": 0}

    # Fan out to every registered channel; one failing channel does not block the others.
    delivered = 0
    for conversation_id, service_url in targets.items():
        try:
            await app.send(conversation_id, MessageActivityInput().add_card(card), service_url=service_url or None)
            delivered += 1
        except Exception:
            logger.exception("Failed to send to %s", conversation_id)
    return {"ok": True, "delivered": delivered}


async def serve() -> None:
    # Reload saved channels on start-up (the container filesystem is ephemeral). Drops any non-channel entries.
    conversations.update({k: v for k, v in (await store.load()).items() if is_channel(k)})
    await app.initialize()
    port = int(os.getenv("PORT", "3978"))
    await uvicorn.Server(uvicorn.Config(server, host="0.0.0.0", port=port)).serve()


def main() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main()
