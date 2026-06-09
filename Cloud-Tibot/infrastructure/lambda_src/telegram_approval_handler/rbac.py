# Defined roles and their permitted actions
ROLES = {
    'viewer':   ['read_plans', 'read_audit'],
    'approver': ['read_plans', 'read_audit', 'approve', 'reject'],
    'deployer': ['read_plans', 'read_audit', 'approve', 'reject', 'rollback'],
}


def can_approve(role: str) -> bool:
    return role in ('approver', 'deployer')


def can_rollback(role: str) -> bool:
    return role == 'deployer'
