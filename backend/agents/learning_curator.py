"""Internal classifier for redacted improvement evidence."""

from agno.agent import Agent
from agno.learn.config import LearnedKnowledgeConfig, LearningMode
from agno.learn.machine import LearningMachine

from agents.models import default_model
from db.session import create_knowledge, get_db
from schemas.learning import LearningCandidate

curator_learning = LearningMachine(
    db=get_db(),
    learned_knowledge=LearnedKnowledgeConfig(
        mode=LearningMode.AGENTIC,
        namespace="menso-approved",
        knowledge=create_knowledge("menso_approved_knowledge"),
        max_updates_per_run=1,
        enable_agent_tools=False,
    )
)

learning_curator = Agent(
    id="menso-learning-curator-internal",
    name="Menso Learning Curator",
    model=default_model(),
    db=get_db(),
    learning=curator_learning,
    add_learnings_to_context=True,
    tools=[],
    output_schema=LearningCandidate,
    instructions=[
        "Convert only the supplied redacted evidence summaries into one conservative, typed improvement proposal.",
        "Do not infer secrets, identities, or facts that are absent from the evidence references.",
        "Preserve affected_agent, scope, evidence_refs, observed_failure, proposed_lesson, instruction diff, "
        "tool/schema proposal, eval cases, privacy notes, and risk as separate review fields.",
        "Set contains_secrets=true on any suspicion. Never include credential values or raw third-party content.",
        "Set generalizable=false when the lesson is user-specific, weakly supported, "
        "or unsuitable for shared behavior.",
        "Code/tool/schema changes and eval cases are inert proposals for Git review; "
        "never edit files, run commands, or deploy.",
    ],
)
