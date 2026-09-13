#!/usr/bin/env python3
"""Repository-wide verification gate.

This script intentionally verifies only the real product/runtime surfaces that
remain in the repository. Legacy multi-provider adapter trees are forbidden.
"""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXAMPILOT = ROOT / "ExamPilot"
ZEROLOSE_PROJECT = ROOT / "ZeroLose" / "ZeroLose.xcodeproj"
ZEROLOSE_SOURCE = ROOT / "ZeroLose" / "ZeroLose"
ZEROLOSE_PROVIDER_SOURCE = ZEROLOSE_SOURCE / "V2" / "Providers"

ZEROLOSE_PRIMARY_PATHS = (
    "Views",
    "V2/UI",
    "V2/Application",
    "V2/Providers",
)

FORBIDDEN_ZEROLOSE_LEGACY_AUTHORITY_TOKENS = (
    "LLMProvider",
    "AIModelNames",
    "llm_provider",
    "OllamaService",
    "customOpenAIReasoningModel",
    "customDeepSeekReasoningModel",
    "customOpenCodeZenReasoningModel",
    "customOpenCodeGoReasoningModel",
    "customOllamaReasoningModel",
    "customOpenAIVisionModel",
    "customDeepSeekVisionModel",
    "customOpenCodeZenVisionModel",
    "customOpenCodeGoVisionModel",
    "customOllamaVisionModel",
    "fallbackProvider",
    "providerFallback",
    "importOpenCodeKeysIfNeeded",
    "auth.json",
    ".local/share/opencode",
)

OBSOLETE_ZEROLOSE_INTERVIEW_SOURCES = (
    "Views/InterviewVaultView.swift",
    "Views/MockInterviewView.swift",
    "Views/TeleprompterView.swift",
    "Views/CheatSheetView.swift",
    "Views/KeyboardDisguiseView.swift",
    "Services/MockInterviewService.swift",
    "ViewModels/CheatSheetViewModel.swift",
)

OBSOLETE_ZEROLOSE_LEGACY_PROVIDER_SOURCES = (
    "Resources/Constants.swift",
    "Services/IntelligenceService.swift",
    "Services/OllamaService.swift",
    "Services/ResponseCacheService.swift",
    "Services/TextAnalysis.swift",
    "Services/LLMPromptBuilder.swift",
    "Services/CodingSandboxService.swift",
    "Services/VaultService.swift",
    "Services/VaultSearchEngine.swift",
    "Services/ActiveRoleProfileService.swift",
    "Services/InterviewKnowledgeMatcher.swift",
    "Services/RAG/SemanticRetriever.swift",
    "Models/InterviewItem.swift",
)

# The legacy provider authority is fully retired: nothing in the product may
# reference these identifiers at all. `llm_provider` is the single historical
# default that one migration-only reader may still inspect.
FORBIDDEN_ZEROLOSE_TREE_TOKENS = (
    "LLMProvider",
    "AIModelNames",
    "OllamaService",
    "customOpenAIReasoningModel",
    "customDeepSeekReasoningModel",
    "customOpenCodeZenReasoningModel",
    "customOpenCodeGoReasoningModel",
    "customOllamaReasoningModel",
    "customOpenAIVisionModel",
    "customDeepSeekVisionModel",
    "customOpenCodeZenVisionModel",
    "customOpenCodeGoVisionModel",
    "customOllamaVisionModel",
)

ALLOWED_ZEROLOSE_LEGACY_DEFAULT_READERS = (
    "V2/Migration/SettingsMigrationCoordinator.swift",
)

FORBIDDEN_ZEROLOSE_INTERVIEW_TOKENS = (
    "InterviewVaultView",
    "MockInterviewView",
    "MockInterviewService",
    "MockInterviewEvaluation",
    "TeleprompterView",
    "TeleprompterWindow",
    "toggleTeleprompterWindow",
    "warmUpInterviewContext",
    "CheatSheetView",
    "CheatSheetViewModel",
    "KeyboardDisguiseView",
)

FORBIDDEN_ZEROLOSE_PROVIDER_TOKENS = (
    "OllamaService",
    "fallbackProvider",
    "providerFallback",
    "retryProvider",
    "alternateProvider",
    "importOpenCodeKeysIfNeeded",
    "opencode.ai/",
    "/zen/go/",
    ".codex/auth",
    ".claude/",
    ".config/opencode",
    ".local/share/opencode",
    "auth.json",
    "credentials.json",
    "/bin/sh",
    "/bin/bash",
    "/bin/zsh",
    "/bin/fish",
    "/bin/dash",
    "/bin/ksh",
    "/bin/csh",
    "/bin/tcsh",
    "/usr/bin/env",
)

FORBIDDEN_ZEROLOSE_EXECUTION_TOKENS = (
    "[ACTION:",
    "actionRegex",
    "handleActions(",
)

OBSOLETE_ZEROLOSE_EXECUTION_SOURCES = (
    "ViewModels/GhostViewModel.swift",
    "Services/ZeroOperator.swift",
    "Services/ComputerUseService.swift",
    "Services/BrowserCDPService.swift",
    "Services/AutomationLibrary.swift",
    "V2/Legacy/AgentCapabilityRegistryAdapter.swift",
)

FORBIDDEN_PATHS = (
    ".agent",
    ".codex",
    ".claude",
    ".opencode",
    "CLAUDE.md",
    "opencode.json",
    "CODEBASE.md",
    "OPERATIONS.md",
    "USAGE_GUIDE.md",
    "scan_results.json",
    "scripts/sync_agents.py",
    "scripts/provider_config_validator.py",
    "scripts/generate_skill_index.py",
    "scripts/fix_agent_tools.py",
    "scripts/prune_memory.py",
    "scripts/skill.sh",
    "scripts/codex-fast.sh",
    "scripts/codex-research.sh",
    "scripts/codex-review.sh",
    "scripts/codex-safe.sh",
)


def fail(message: str) -> int:
    print(f"[FAIL] {message}", file=sys.stderr)
    return 1


def run(command: list[str], *, cwd: Path) -> bool:
    printable = " ".join(command)
    print(f"\n[RUN] ({cwd.relative_to(ROOT) if cwd != ROOT else '.'}) {printable}")
    completed = subprocess.run(command, cwd=cwd)
    if completed.returncode != 0:
        print(f"[FAIL] exit={completed.returncode}: {printable}", file=sys.stderr)
        return False
    print(f"[OK] {printable}")
    return True


def run_expect_output(
    command: list[str],
    *,
    cwd: Path,
    expected: str,
) -> bool:
    printable = " ".join(command)
    print(f"\n[RUN] ({cwd.relative_to(ROOT) if cwd != ROOT else '.'}) {printable}")
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = completed.stdout or ""
    if output:
        print(output, end="" if output.endswith("\n") else "\n")
    if completed.returncode != 0:
        print(f"[FAIL] exit={completed.returncode}: {printable}", file=sys.stderr)
        return False
    if expected not in output:
        print(
            f"[FAIL] expected output token not found: {expected!r}",
            file=sys.stderr,
        )
        return False
    print(f"[OK] {printable} contains {expected!r}")
    return True


def verify_layout() -> bool:
    ok = True
    for relative in FORBIDDEN_PATHS:
        path = ROOT / relative
        if path.exists() or path.is_symlink():
            print(f"[FAIL] legacy path still exists: {relative}", file=sys.stderr)
            ok = False

    required = (
        ROOT / "README.md",
        ROOT / "AGENTS.md",
        EXAMPILOT / "Package.swift",
        ROOT / ".github" / "workflows" / "exampilot.yml",
    )
    for path in required:
        if not path.exists():
            print(f"[FAIL] required path missing: {path.relative_to(ROOT)}", file=sys.stderr)
            ok = False

    readme = ROOT / "README.md"
    if readme.exists():
        content = readme.read_text(encoding="utf-8", errors="replace").strip()
        if len(content) < 500 or content.lower() == "placeholder":
            print("[FAIL] README.md is incomplete", file=sys.stderr)
            ok = False

    return ok


def verify_zerolose_legacy_demolition() -> bool:
    if not ZEROLOSE_SOURCE.is_dir():
        print("[INFO] ZeroLose source tree not present; skipping legacy demolition scan")
        return True

    ok = True
    for relative in OBSOLETE_ZEROLOSE_EXECUTION_SOURCES:
        path = ZEROLOSE_SOURCE / relative
        if path.exists() or path.is_symlink():
            print(
                f"[FAIL] obsolete ZeroLose execution source still exists: {relative}",
                file=sys.stderr,
            )
            ok = False

    for path in ZEROLOSE_SOURCE.rglob("*.swift"):
        content = path.read_text(encoding="utf-8", errors="replace")
        for token in FORBIDDEN_ZEROLOSE_EXECUTION_TOKENS:
            if token in content:
                relative = path.relative_to(ROOT)
                print(
                    f"[FAIL] forbidden ZeroLose execution token {token!r} in {relative}",
                    file=sys.stderr,
                )
                ok = False

    return ok


def verify_zerolose_provider_fabric() -> bool:
    if not ZEROLOSE_PROVIDER_SOURCE.is_dir():
        print("[FAIL] ZeroLose V2 provider source tree is missing", file=sys.stderr)
        return False

    ok = True
    for path in ZEROLOSE_PROVIDER_SOURCE.rglob("*.swift"):
        content = path.read_text(encoding="utf-8", errors="replace")
        for token in FORBIDDEN_ZEROLOSE_PROVIDER_TOKENS:
            if token in content:
                relative = path.relative_to(ROOT)
                print(
                    f"[FAIL] forbidden ZeroLose provider token {token!r} in {relative}",
                    file=sys.stderr,
                )
                ok = False

    return ok


def verify_zerolose_provider_authority() -> bool:
    """Primary Chat/Agent/UI paths must not reach legacy provider authority."""
    if not ZEROLOSE_SOURCE.is_dir():
        print("[INFO] ZeroLose source tree not present; skipping provider authority scan")
        return True

    ok = True

    # The retired legacy provider stack must stay deleted.
    for relative in OBSOLETE_ZEROLOSE_LEGACY_PROVIDER_SOURCES:
        path = ZEROLOSE_SOURCE / relative
        if path.exists() or path.is_symlink():
            print(
                f"[FAIL] retired legacy provider source is back: {relative}",
                file=sys.stderr,
            )
            ok = False

    # No product source may reference legacy provider authority identifiers, and
    # only the migration coordinator may read the historical provider default.
    for path in ZEROLOSE_SOURCE.rglob("*.swift"):
        content = path.read_text(encoding="utf-8", errors="replace")
        relative = str(path.relative_to(ZEROLOSE_SOURCE))
        for token in FORBIDDEN_ZEROLOSE_TREE_TOKENS:
            if token in content:
                print(
                    f"[FAIL] retired provider authority token {token!r} in "
                    f"ZeroLose/{relative}",
                    file=sys.stderr,
                )
                ok = False
        if "llm_provider" in content and relative not in ALLOWED_ZEROLOSE_LEGACY_DEFAULT_READERS:
            print(
                f"[FAIL] historical provider default \"llm_provider\" is read by "
                f"ZeroLose/{relative}; only the migration coordinator may read it",
                file=sys.stderr,
            )
            ok = False

    inspected = 0
    for relative in ZEROLOSE_PRIMARY_PATHS:
        directory = ZEROLOSE_SOURCE / relative
        if not directory.is_dir():
            print(
                f"[FAIL] ZeroLose primary path is missing: {relative}",
                file=sys.stderr,
            )
            ok = False
            continue
        for path in directory.rglob("*.swift"):
            inspected += 1
            content = path.read_text(encoding="utf-8", errors="replace")
            for token in FORBIDDEN_ZEROLOSE_LEGACY_AUTHORITY_TOKENS:
                if token in content:
                    print(
                        f"[FAIL] legacy provider authority token {token!r} in "
                        f"{path.relative_to(ROOT)}",
                        file=sys.stderr,
                    )
                    ok = False

    if inspected == 0:
        print("[FAIL] no ZeroLose primary path sources were inspected", file=sys.stderr)
        ok = False

    # Automatic credential scraping from provider config files must stay removed.
    app_source = ZEROLOSE_SOURCE / "ZeroLoseApp.swift"
    if app_source.exists():
        app_content = app_source.read_text(encoding="utf-8", errors="replace")
        for token in ("importOpenCodeKeysIfNeeded", ".local/share/opencode", "auth.json"):
            if token in app_content:
                print(
                    f"[FAIL] ZeroLose app launch still performs legacy credential "
                    f"import: {token!r}",
                    file=sys.stderr,
                )
                ok = False

    return ok


def verify_zerolose_interview_demolition() -> bool:
    """Interview product surfaces and copy must stay removed."""
    if not ZEROLOSE_SOURCE.is_dir():
        print("[INFO] ZeroLose source tree not present; skipping interview demolition scan")
        return True

    ok = True
    for relative in OBSOLETE_ZEROLOSE_INTERVIEW_SOURCES:
        path = ZEROLOSE_SOURCE / relative
        if path.exists() or path.is_symlink():
            print(
                f"[FAIL] removed interview source is back: {relative}",
                file=sys.stderr,
            )
            ok = False

    for path in ZEROLOSE_SOURCE.rglob("*.swift"):
        content = path.read_text(encoding="utf-8", errors="replace")
        for token in FORBIDDEN_ZEROLOSE_INTERVIEW_TOKENS:
            if token in content:
                print(
                    f"[FAIL] interview runtime token {token!r} in {path.relative_to(ROOT)}",
                    file=sys.stderr,
                )
                ok = False

    readme = ROOT / "ZeroLose" / "README.md"
    if readme.exists():
        lowered = readme.read_text(encoding="utf-8", errors="replace").lower()
        for token in ("interview", "mülakat", "teleprompter"):
            if token in lowered:
                print(
                    f"[FAIL] ZeroLose/README.md still positions the product as an "
                    f"interview assistant ({token!r})",
                    file=sys.stderr,
                )
                ok = False

    info_plist = ZEROLOSE_SOURCE / "Info.plist"
    if info_plist.exists():
        lowered = info_plist.read_text(encoding="utf-8", errors="replace").lower()
        for token in ("interview", "during meetings"):
            if token in lowered:
                print(
                    f"[FAIL] Info.plist privacy copy still describes an interview "
                    f"assistant ({token!r})",
                    file=sys.stderr,
                )
                ok = False

    return ok


def verify_exampilot() -> bool:
    if not EXAMPILOT.is_dir():
        return False
    if shutil.which("swift") is None:
        print("[FAIL] swift is required to verify ExamPilot", file=sys.stderr)
        return False

    release_binary = EXAMPILOT / ".build" / "release" / "exampilot"
    return (
        run(["swift", "test"], cwd=EXAMPILOT)
        and run(["swift", "build", "-c", "release"], cwd=EXAMPILOT)
        and run_expect_output(
            [str(release_binary), "--help"],
            cwd=EXAMPILOT,
            expected="--verbose",
        )
    )


def zerolose_test_destination() -> str:
    """Concrete destination for `xcodebuild test` (generic/platform cannot test)."""
    machine = platform.machine()
    if machine in ("arm64", "aarch64"):
        return "platform=macOS,arch=arm64"
    if machine in ("x86_64", "amd64"):
        return "platform=macOS,arch=x86_64"
    return "platform=macOS"


def verify_zerolose() -> bool:
    if not ZEROLOSE_PROJECT.exists():
        print("[INFO] ZeroLose project not present; skipping Xcode build and tests")
        return True
    if shutil.which("xcodebuild") is None:
        print("[INFO] xcodebuild unavailable; skipping ZeroLose build and tests")
        return True

    derived_data = ROOT / "ZeroLose" / "build" / "VerificationDerivedData"

    if not run(
        [
            "xcodebuild",
            "-project",
            str(ZEROLOSE_PROJECT),
            "-scheme",
            "ZeroLose",
            "-configuration",
            "Debug",
            "-destination",
            "generic/platform=macOS",
            "-derivedDataPath",
            str(derived_data),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=ROOT,
    ):
        return False

    # The build above uses generic/platform=macOS, which cannot run the test action.
    # Run the real ZeroLose test suite against a concrete host destination so the
    # repository gate cannot pass while ZeroLoseTests are failing.
    return run(
        [
            "xcodebuild",
            "-project",
            str(ZEROLOSE_PROJECT),
            "-scheme",
            "ZeroLose",
            "-configuration",
            "Debug",
            "-destination",
            zerolose_test_destination(),
            "-derivedDataPath",
            str(derived_data),
            "test",
        ],
        cwd=ROOT,
    )


def main() -> int:
    print("Akıllı Asistan repository verification")

    if not verify_layout():
        return fail("repository layout verification failed")

    if not verify_zerolose_legacy_demolition():
        return fail("ZeroLose legacy execution demolition verification failed")

    if not verify_zerolose_provider_fabric():
        return fail("ZeroLose provider fabric verification failed")

    if not verify_zerolose_provider_authority():
        return fail("ZeroLose provider authority verification failed")

    if not verify_zerolose_interview_demolition():
        return fail("ZeroLose interview demolition verification failed")

    if not verify_exampilot():
        return fail("ExamPilot verification failed")

    if not verify_zerolose():
        return fail("ZeroLose build/test verification failed")

    print("\n[OK] repository verification completed successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
