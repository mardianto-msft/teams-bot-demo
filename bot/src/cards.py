from typing import Any

from microsoft_teams.cards.core import AdaptiveCard

MAX_DESCRIPTION = 500

# action -> (label, Adaptive Card color)
_STATUS = {
    "opened": ("Opened", "Good"),
    "reopened": ("Reopened", "Warning"),
    "closed": ("Closed", "Attention"),
    "edited": ("Updated", "Accent"),
}


def _truncate(text: str | None) -> str:
    text = (text or "").strip()
    if not text:
        return "_No description provided._"
    if len(text) > MAX_DESCRIPTION:
        return text[:MAX_DESCRIPTION].rstrip() + "…"
    return text


def build_issue_card(action: str, issue: dict[str, Any], repo_name: str, sender: str) -> AdaptiveCard:
    label, color = _STATUS.get(action, (action.capitalize(), "Default"))
    number = issue["number"]
    state = issue.get("state", "open")
    if action == "closed" and issue.get("state_reason") == "not_planned":
        label = "Closed as not planned"

    labels = ", ".join(lbl["name"] for lbl in issue.get("labels", [])) or "None"
    assignees = ", ".join(a["login"] for a in issue.get("assignees", [])) or "Unassigned"

    return AdaptiveCard.model_validate(
        {
            "type": "AdaptiveCard",
            "version": "1.5",
            "body": [
                {
                    "type": "TextBlock",
                    "text": f"Issue {label.lower()} · {repo_name}",
                    "size": "Small",
                    "weight": "Bolder",
                    "color": color,
                },
                {
                    "type": "TextBlock",
                    "text": f"#{number} {issue['title']}",
                    "size": "Large",
                    "weight": "Bolder",
                    "wrap": True,
                },
                {"type": "TextBlock", "text": _truncate(issue.get("body")), "wrap": True},
                {
                    "type": "FactSet",
                    "facts": [
                        {"title": "Status", "value": state.capitalize()},
                        {"title": "By", "value": sender},
                        {"title": "Labels", "value": labels},
                        {"title": "Assignees", "value": assignees},
                    ],
                },
            ],
            "actions": [
                {"type": "Action.OpenUrl", "title": "Open issue on GitHub", "url": issue["html_url"]},
            ],
        }
    )
