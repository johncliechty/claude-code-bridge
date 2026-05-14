"""Tests for v0.1.0 permission gates."""
from bridge.permissions import is_destructive, requires_admin, validate_prompt


def test_rm_rf_blocked():
    assert is_destructive("rm -rf /tmp") is not None
    assert is_destructive("rm -rf .") is not None


def test_remove_item_recursive_blocked():
    assert is_destructive("Remove-Item -Recurse -Force C:\\foo") is not None
    assert is_destructive("Remove-Item -Force -Recurse C:\\foo") is not None


def test_git_push_force_blocked():
    assert is_destructive("git push --force origin main") is not None
    assert is_destructive("git push --force-with-lease origin main") is not None


def test_git_reset_hard_blocked():
    assert is_destructive("git reset --hard HEAD~3") is not None


def test_git_branch_force_delete_blocked():
    assert is_destructive("git branch -D feature/foo") is not None


def test_format_volume_blocked():
    assert is_destructive("Format-Volume -DriveLetter D") is not None


def test_shutdown_blocked():
    assert is_destructive("shutdown /s /t 0") is not None


def test_normal_commands_allowed():
    assert is_destructive("git status") is None
    assert is_destructive("npm install foo") is None
    assert is_destructive("python -m pytest") is None
    assert is_destructive("git push origin main") is None
    assert is_destructive("Remove-Item C:\\foo\\bar.txt") is None  # non-recursive, non-force


def test_admin_detection_powershell():
    assert requires_admin("Start-Process powershell -Verb RunAs -ArgumentList '-Command winget install ...'") is not None


def test_admin_detection_unix():
    assert requires_admin("sudo apt update") is not None
    assert requires_admin(" sudo  -i") is not None


def test_admin_normal_allowed():
    assert requires_admin("npm install foo") is None
    assert requires_admin("Pseudo Code") is None  # the word 'sudo' is inside 'Pseudo' but boundary doesn't match


def test_validate_prompt_blocks_destructive():
    is_safe, reason = validate_prompt("Please rm -rf /home")
    assert not is_safe
    assert reason is not None
    assert "rm -rf" in reason


def test_validate_prompt_allows_normal():
    is_safe, reason = validate_prompt("Please run git status and report")
    assert is_safe
    assert reason is None
