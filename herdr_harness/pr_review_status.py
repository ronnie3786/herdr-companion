"""GitHub's authenticated viewer review state, separate from the PR's state.

All connections are bounded. Reviews are filtered by the authenticated login on
GitHub, so other people's reviews and drafts cannot become the viewer's status.
"""
from __future__ import annotations

from datetime import datetime
from typing import Any, Mapping


VIEWER_QUERY = "query { viewer { login } }"
REVIEW_QUERY = """query($owner:String!,$repo:String!,$number:Int!,$viewer:String!){
  repository(owner:$owner,name:$repo){pullRequest(number:$number){
    headRefOid viewerDidAuthor viewerLatestReviewRequest{id}
    reviews(last:1,author:$viewer,states:[APPROVED,CHANGES_REQUESTED,COMMENTED,DISMISSED]){
      nodes{state submittedAt commit{oid}}
    }
    pending:reviews(first:1,author:$viewer,states:[PENDING]){
      nodes{comments{totalCount}}
    }
    timelineItems(last:100,itemTypes:[REVIEW_REQUESTED_EVENT]){
      nodes{... on ReviewRequestedEvent{createdAt requestedReviewer{... on User{login}}}}
      pageInfo{hasPreviousPage}
    }
  }}
}"""


def viewer_review_summary(pull: Mapping[str, Any], login: str) -> dict[str, Any]:
    """Reject incomplete data instead of inventing a fresh not-reviewed state."""
    head, own = pull["headRefOid"], pull["viewerDidAuthor"]
    if not isinstance(head, str) or not head or type(own) is not bool:
        raise ValueError("Invalid PR viewer metadata")
    reviews = pull["reviews"]["nodes"]
    pending = pull["pending"]["nodes"]
    timeline = pull["timelineItems"]
    if not isinstance(reviews, list) or not isinstance(pending, list):
        raise ValueError("Invalid review connection")
    review = reviews[0] if reviews else {}
    review_state = review.get("state")
    states = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes_requested",
              "COMMENTED": "commented", "DISMISSED": "not_reviewed"}
    if review and review_state not in states:
        raise ValueError("Unknown GitHub review state")
    reviewed_at = review.get("submittedAt")
    reviewed_commit = (review.get("commit") or {}).get("oid")
    requested = pull["viewerLatestReviewRequest"] is not None
    requests = [event["createdAt"] for event in timeline["nodes"]
                if event and (event.get("requestedReviewer") or {}).get("login", "").casefold() == login.casefold()]
    if requested and reviewed_at and not requests and timeline["pageInfo"]["hasPreviousPage"] and not pending:
        raise ValueError("Review request history is incomplete")
    def timestamp(value: str) -> datetime:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            raise ValueError("Missing GitHub timestamp timezone")
        return result

    requested_again = bool(requested and reviewed_at and any(timestamp(date) > timestamp(reviewed_at) for date in requests))
    changed = bool(reviewed_at and reviewed_commit and reviewed_commit != head)
    count = pending[0]["comments"]["totalCount"] if pending else 0
    if type(count) is not int or count < 0:
        raise ValueError("Invalid pending comment count")
    state = "pending" if pending else "re_review_requested" if requested_again or changed else states.get(review_state, "not_reviewed")
    return {"state": state, "pending_comment_count": count,
            "needs_user": not own and state in {"pending", "re_review_requested"},
            "is_own_pr": own, "reviewed_at": reviewed_at,
            "reviewed_commit": reviewed_commit, "head_commit": head,
            "review_requested": requested}
