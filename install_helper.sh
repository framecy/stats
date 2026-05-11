#!/bin/bash

set -euo pipefail

HELPER_ID="eu.exelban.Stats.SMC.Helper"
HELPER_SRC="/Applications/Stats.app/Contents/Library/LaunchServices/$HELPER_ID"
DEST_TOOL="/Library/PrivilegedHelperTools/$HELPER_ID"
DEST_PLIST="/Library/LaunchDaemons/$HELPER_ID.plist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo "       $1"; }
FAIL_COUNT=0

# ── Root check ──────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

echo -e "\n${BOLD}=== Pre-flight ===${NC}"

# Source binary must exist
if [ ! -f "$HELPER_SRC" ]; then
    fail "Helper not found: $HELPER_SRC"
    info "Ensure Stats.app is in /Applications"
    exit 1
fi
pass "Source helper found"

# Verify code signature of the source binary
SRC_SIGN=$(codesign -dvv "$HELPER_SRC" 2>&1 || true)
if echo "$SRC_SIGN" | grep -q "Developer ID Application"; then
    TEAM=$(echo "$SRC_SIGN" | awk '/TeamIdentifier/{print $NF}')
    pass "Source signed with Developer ID (team: $TEAM)"
elif echo "$SRC_SIGN" | grep -q "adhoc"; then
    warn "Source is ad-hoc signed — XPC auth will allow only if the app is also ad-hoc"
else
    warn "Source signature status unknown"
fi

# ── Installation ────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Installing ===${NC}"

cp "$HELPER_SRC" "$DEST_TOOL"
chown root:wheel "$DEST_TOOL"
chmod 755 "$DEST_TOOL"
info "Binary installed to $DEST_TOOL"

# tee writes as root — avoids the redirect-as-caller-user bug in the old script
tee "$DEST_PLIST" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_ID</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_ID</key>
        <true/>
    </dict>
    <key>Program</key>
    <string>$DEST_TOOL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST_TOOL</string>
    </array>
</dict>
</plist>
EOF
chown root:wheel "$DEST_PLIST"
chmod 644 "$DEST_PLIST"
info "LaunchDaemon plist written"

# ── Permission verification ──────────────────────────────────────────────────
echo -e "\n${BOLD}=== Permission verification ===${NC}"

TOOL_OWNER=$(stat -f "%Su:%Sg" "$DEST_TOOL")
TOOL_PERMS=$(stat -f "%OLp" "$DEST_TOOL")
[ "$TOOL_OWNER" = "root:wheel" ] && pass "Binary owner  : $TOOL_OWNER" || fail "Binary owner  : $TOOL_OWNER (want root:wheel)"
[ "$TOOL_PERMS" = "755" ]        && pass "Binary perms  : $TOOL_PERMS" || fail "Binary perms  : $TOOL_PERMS (want 755)"

PLIST_OWNER=$(stat -f "%Su:%Sg" "$DEST_PLIST")
PLIST_PERMS=$(stat -f "%OLp" "$DEST_PLIST")
[ "$PLIST_OWNER" = "root:wheel" ] && pass "Plist owner   : $PLIST_OWNER" || fail "Plist owner   : $PLIST_OWNER (want root:wheel)"
[ "$PLIST_PERMS" = "644" ]        && pass "Plist perms   : $PLIST_PERMS" || fail "Plist perms   : $PLIST_PERMS (want 644)"

# Verify installed binary's code signature
DEST_SIGN=$(codesign -dvv "$DEST_TOOL" 2>&1 || true)
if echo "$DEST_SIGN" | grep -q "Developer ID Application"; then
    pass "Installed binary: Developer ID signed"
elif echo "$DEST_SIGN" | grep -q "adhoc"; then
    warn "Installed binary: ad-hoc signed"
else
    fail "Installed binary: not signed"
fi

# ── Plist structure verification ─────────────────────────────────────────────
echo -e "\n${BOLD}=== Plist structure ===${NC}"

PLIST_LABEL=$(/usr/libexec/PlistBuddy -c "Print :Label" "$DEST_PLIST" 2>/dev/null || echo "")
PLIST_PROGRAM=$(/usr/libexec/PlistBuddy -c "Print :Program" "$DEST_PLIST" 2>/dev/null || echo "")
PLIST_MACH=$(/usr/libexec/PlistBuddy -c "Print :MachServices:$HELPER_ID" "$DEST_PLIST" 2>/dev/null || echo "")

[ "$PLIST_LABEL"   = "$HELPER_ID"  ] && pass "Label   : $PLIST_LABEL"   || fail "Label mismatch: '$PLIST_LABEL'"
[ "$PLIST_PROGRAM" = "$DEST_TOOL"  ] && pass "Program : $PLIST_PROGRAM" || fail "Program mismatch: '$PLIST_PROGRAM'"
[ "$PLIST_MACH"    = "true"        ] && pass "MachServices.$HELPER_ID : true" || fail "MachServices entry missing or incorrect"

# ── Load service ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Loading service ===${NC}"

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -ge 13 ] 2>/dev/null; then
    # Modern API: bootout is idempotent, bootstrap registers, enable persists across reboots
    launchctl bootout "system/$HELPER_ID" 2>/dev/null || true
    launchctl bootstrap system "$DEST_PLIST"
    launchctl enable "system/$HELPER_ID"
    info "Loaded via launchctl bootstrap + enable (macOS $MACOS_MAJOR)"
else
    launchctl unload "$DEST_PLIST" 2>/dev/null || true
    launchctl load -w "$DEST_PLIST"
    info "Loaded via launchctl load -w (macOS $MACOS_MAJOR)"
fi

# Give launchd a moment to register the Mach port
sleep 1

# ── Liveness check ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Liveness check ===${NC}"

# The helper is on-demand (exits when no XPC clients). Liveness = Mach port registered.
if launchctl print "system/$HELPER_ID" &>/dev/null; then
    pass "Mach service registered with launchd"
    STATE=$(launchctl print "system/$HELPER_ID" 2>/dev/null | awk '/\bstate\b/{print $3}')
    info "State: ${STATE:-unknown}"
    PID=$(launchctl print "system/$HELPER_ID" 2>/dev/null | awk '/\bpid\b/{print $3}')
    [ -n "$PID" ] && info "PID  : $PID (currently running)" || info "PID  : not running (normal — waits for XPC connection)"
else
    fail "Mach service NOT registered — launchd did not load the daemon"
fi

# ── Reboot persistence check ─────────────────────────────────────────────────
echo -e "\n${BOLD}=== Reboot persistence ===${NC}"

# Plist in /Library/LaunchDaemons is loaded at boot by launchd automatically
if [ -f "$DEST_PLIST" ]; then
    pass "Plist present in /Library/LaunchDaemons (auto-loaded on boot)"
else
    fail "Plist missing from /Library/LaunchDaemons"
fi

# Check that the service is not disabled (disabled list overrides the plist)
DISABLED=$(launchctl print-disabled system 2>/dev/null | grep "\"$HELPER_ID\"" | awk '{print $NF}' || true)
if [ "$DISABLED" = "true" ]; then
    fail "Service is marked DISABLED — it will NOT auto-load after reboot"
    info "Fix: sudo launchctl enable system/$HELPER_ID"
else
    pass "Service is enabled (not in disabled list — will auto-load on reboot)"
fi

# Helper log (written by the helper binary itself on each start)
if [ -f /tmp/stats_helper.log ]; then
    LOGLINE=$(tail -1 /tmp/stats_helper.log)
    pass "Helper log: $LOGLINE"
else
    warn "No helper log at /tmp/stats_helper.log (normal until first XPC connection)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Summary ===${NC}"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC} Restart Stats.app to connect."
else
    echo -e "${RED}$FAIL_COUNT check(s) failed.${NC} Review the output above before restarting Stats.app."
    exit 1
fi
