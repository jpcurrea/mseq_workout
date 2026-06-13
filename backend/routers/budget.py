"""
Budget routes: accounts and goals → compute the single "spendable now" number.
"""
import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from database import get_session, Account, BudgetGoal
from dependencies import get_current_user_id

router = APIRouter(prefix="/budget", tags=["budget"])


# ── Schemas ────────────────────────────────────────────────────────────────────

class AccountCreate(BaseModel):
    name: str
    balance: float


class AccountUpdate(BaseModel):
    name: Optional[str] = None
    balance: Optional[float] = None


class GoalCreate(BaseModel):
    name: str
    target_amount: float
    target_date: Optional[str] = None   # YYYY-MM-DD
    current_saved: float = 0.0


class GoalUpdate(BaseModel):
    name: Optional[str] = None
    target_amount: Optional[float] = None
    target_date: Optional[str] = None
    current_saved: Optional[float] = None


# ── Summary ────────────────────────────────────────────────────────────────────

@router.get("/summary")
async def budget_summary(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    """The headline number: how much can I spend right now and still hit my goals?"""
    accounts = session.query(Account).filter(Account.user_id == user_id).all()
    goals = session.query(BudgetGoal).filter(BudgetGoal.user_id == user_id).all()

    total_balance = sum(a.balance for a in accounts)
    total_needed = sum(max(g.target_amount - g.current_saved, 0.0) for g in goals)
    spendable_now = total_balance - total_needed

    return {
        "total_balance": total_balance,
        "total_needed_by_goals": total_needed,
        "spendable_now": spendable_now,
        "account_count": len(accounts),
        "goal_count": len(goals),
    }


# ── Account endpoints ──────────────────────────────────────────────────────────

@router.get("/accounts")
async def list_accounts(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    accounts = session.query(Account).filter(Account.user_id == user_id).all()
    return [
        {"id": a.id, "name": a.name, "balance": a.balance,
         "updated_at": a.updated_at.isoformat() if a.updated_at else None}
        for a in accounts
    ]


@router.post("/accounts")
async def create_account(
    body: AccountCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    account = Account(user_id=user_id, name=body.name, balance=body.balance,
                      updated_at=datetime.datetime.utcnow())
    session.add(account)
    session.commit()
    session.refresh(account)
    return {"id": account.id, "name": account.name, "balance": account.balance}


@router.put("/accounts/{account_id}")
async def update_account(
    account_id: int,
    body: AccountUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    account = session.query(Account).filter(Account.id == account_id, Account.user_id == user_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    if body.name is not None:
        account.name = body.name
    if body.balance is not None:
        account.balance = body.balance
    account.updated_at = datetime.datetime.utcnow()
    session.commit()
    return {"id": account.id, "name": account.name, "balance": account.balance}


@router.delete("/accounts/{account_id}")
async def delete_account(
    account_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    account = session.query(Account).filter(Account.id == account_id, Account.user_id == user_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    session.delete(account)
    session.commit()
    return {"message": "Account deleted"}


# ── Goal endpoints ─────────────────────────────────────────────────────────────

@router.get("/goals")
async def list_goals(
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    goals = session.query(BudgetGoal).filter(BudgetGoal.user_id == user_id).all()
    return [
        {
            "id": g.id,
            "name": g.name,
            "target_amount": g.target_amount,
            "current_saved": g.current_saved,
            "still_needed": max(g.target_amount - g.current_saved, 0.0),
            "target_date": g.target_date.isoformat() if g.target_date else None,
            "created_at": g.created_at.isoformat(),
        }
        for g in goals
    ]


@router.post("/goals")
async def create_goal(
    body: GoalCreate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    target_date = None
    if body.target_date:
        try:
            target_date = datetime.date.fromisoformat(body.target_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="target_date must be YYYY-MM-DD")

    goal = BudgetGoal(
        user_id=user_id,
        name=body.name,
        target_amount=body.target_amount,
        target_date=target_date,
        current_saved=body.current_saved,
    )
    session.add(goal)
    session.commit()
    session.refresh(goal)
    return {"id": goal.id, "name": goal.name, "target_amount": goal.target_amount,
            "current_saved": goal.current_saved, "target_date": body.target_date}


@router.put("/goals/{goal_id}")
async def update_goal(
    goal_id: int,
    body: GoalUpdate,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    goal = session.query(BudgetGoal).filter(BudgetGoal.id == goal_id, BudgetGoal.user_id == user_id).first()
    if not goal:
        raise HTTPException(status_code=404, detail="Goal not found")
    if body.name is not None:
        goal.name = body.name
    if body.target_amount is not None:
        goal.target_amount = body.target_amount
    if body.current_saved is not None:
        goal.current_saved = body.current_saved
    if body.target_date is not None:
        try:
            goal.target_date = datetime.date.fromisoformat(body.target_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="target_date must be YYYY-MM-DD")
    session.commit()
    return {"id": goal.id, "name": goal.name, "target_amount": goal.target_amount,
            "current_saved": goal.current_saved}


@router.delete("/goals/{goal_id}")
async def delete_goal(
    goal_id: int,
    user_id: int = Depends(get_current_user_id),
    session: Session = Depends(get_session),
):
    goal = session.query(BudgetGoal).filter(BudgetGoal.id == goal_id, BudgetGoal.user_id == user_id).first()
    if not goal:
        raise HTTPException(status_code=404, detail="Goal not found")
    session.delete(goal)
    session.commit()
    return {"message": "Goal deleted"}
