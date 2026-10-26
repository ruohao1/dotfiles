"""Read-only deployment evidence and recovery decisions, without release policy."""
from pathlib import Path

from .model import Conflict, canonical_home, ownership_root, read_owner, safe_directory
from .transaction import Journal, Runtime


def inspect_status(home):
    """Return unmanaged/pending/active status and manifests; reject inconsistent evidence."""
    home = canonical_home(home)
    owner = read_owner(home)
    transactions = ownership_root(home)/'transactions'
    unpublished = []
    if transactions.exists():
        safe_directory(transactions)
        for entry in transactions.iterdir():
            retained = Journal(home, entry.name)
            if (retained.data['phase'] == 'prepared'
                    and retained.data.get('parentTransaction') == (owner['transactionId'] if owner else None)):
                unpublished.append(retained)
    if len(unpublished) > 1:
        raise Conflict('multiple unfinished journals require explicit recovery')
    if unpublished:
        journal = unpublished[0]
    elif owner is None:
        locked = (ownership_root(home)/'lock').exists()
        return {'state': 'pending' if locked else 'unmanaged', 'retained': [],
                'detail': 'Deployment lock requires inspection.' if locked else ''}
    else:
        journal = Journal(home, owner['transactionId'])
    if not unpublished and (owner['journalPath'] != str(journal.path)
            or owner['manifestFingerprint'] != journal.data['plan']['manifestFingerprint']):
        raise Conflict('owner and journal disagree')
    result = {'state': 'pending', 'transactionId': journal.data['transactionId'], 'retained': []}
    for generation, manifest in journal.data['generations'].items():
        if manifest['activationPackage'] != generation:
            raise Conflict('retained generation identity mismatch')
        result['retained'].append({'generation': generation, 'manifest': manifest})
    if (unpublished or owner['phase'] != 'home-manager' or journal.data['phase'] != 'active'
            or journal.data.get('rollback', {}).get('state') == 'intent'):
        return result
    generation = owner['selectedGeneration']
    manifest = journal.data['generations'][generation]
    if (journal.data['selectedGeneration'] != generation
            or Runtime(home).selected_generation(manifest) != generation or not Path(generation).is_dir()):
        raise Conflict('selected Home Manager profile differs from ownership evidence')
    return dict(result, state='active', generation=generation, manifest=manifest)


def recovery_action(home, transaction):
    """Select apply, restore-legacy, or rollback with its recorded generation."""
    home = canonical_home(home)
    journal_path = ownership_root(home)/'transactions'/transaction
    if journal_path.exists():
        journal = Journal(home, transaction)
        rollback = journal.data.get('rollback', {})
        if rollback.get('state') in ('intent', 'complete'):
            return {'command': 'rollback', 'generation': rollback['generation']}
        owner = read_owner(home)
        if not owner or owner['transactionId'] != transaction:
            return {'command': 'restore-legacy'}
    return {'command': 'apply'}


def retained_plan(home, transaction):
    """Return the validated journal's plan, or None before its directory exists."""
    home = canonical_home(home)
    journal_path = home/'.local/state/dotfiles-ownership/transactions'/transaction
    if journal_path.exists():
        return Journal(home, transaction).data['plan']
    return None
