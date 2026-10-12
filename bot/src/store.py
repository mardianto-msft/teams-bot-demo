import json
import logging
import os
from pathlib import Path
from typing import Protocol

from azure.identity.aio import DefaultAzureCredential
from azure.storage.blob.aio import BlobClient

logger = logging.getLogger(__name__)

# conversation id -> service url
Conversations = dict[str, str]


class ConversationStore(Protocol):
    async def load(self) -> Conversations: ...

    async def save(self, conversations: Conversations) -> None: ...


class FileStore:
    """Local development store."""

    def __init__(self, path: str = ".conversations.json"):
        self._path = Path(path)

    async def load(self) -> Conversations:
        if not self._path.exists():
            return {}
        return json.loads(self._path.read_text())

    async def save(self, conversations: Conversations) -> None:
        self._path.write_text(json.dumps(conversations))


class BlobStore:
    """Azure Blob Storage store, authenticated with the user-assigned managed identity."""

    def __init__(self, account_url: str, container: str, managed_identity_client_id: str | None):
        self._credential = DefaultAzureCredential(managed_identity_client_id=managed_identity_client_id)
        self._blob = BlobClient(
            account_url=account_url,
            container_name=container,
            blob_name="conversations.json",
            credential=self._credential,
        )

    async def load(self) -> Conversations:
        from azure.core.exceptions import ResourceNotFoundError

        try:
            stream = await self._blob.download_blob()
            return json.loads(await stream.readall())
        except ResourceNotFoundError:
            return {}

    async def save(self, conversations: Conversations) -> None:
        await self._blob.upload_blob(json.dumps(conversations), overwrite=True)


def create_store() -> ConversationStore:
    account_url = os.getenv("STORAGE_ACCOUNT_URL")
    if account_url:
        return BlobStore(
            account_url,
            os.getenv("STORAGE_CONTAINER", "state"),
            os.getenv("MANAGED_IDENTITY_CLIENT_ID") or os.getenv("CLIENT_ID"),
        )
    logger.warning("STORAGE_ACCOUNT_URL not set; using local file store")
    return FileStore()
