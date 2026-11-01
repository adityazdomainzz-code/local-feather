#!/usr/bin/env bash
#
# ui.sh — Patch FeatherPanel Admin → VDS → Nodes create UI to add LocalNode driver.
# Also applies minimal backend + migration hooks when found.
#
# Usage (on the panel server):
#   sudo bash ui.sh
#   sudo bash ui.sh --panel-root /var/www/featherpanel
#   sudo bash ui.sh --frontend /path/to/frontendv2 --backend /path/to/backend
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*"; exit 1; }

PANEL_ROOT=""
FRONTEND_DIR=""
BACKEND_DIR=""
SKIP_BACKEND=0
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-root) PANEL_ROOT="$2"; shift 2 ;;
    --frontend)   FRONTEND_DIR="$2"; shift 2 ;;
    --backend)    BACKEND_DIR="$2"; shift 2 ;;
    --skip-backend) SKIP_BACKEND=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--panel-root DIR] [--frontend DIR] [--backend DIR] [--skip-backend] [--skip-build]"
      exit 0
      ;;
    *) err "Unknown arg: $1" ;;
  esac
done

# ── locate install ──────────────────────────────────────────────
detect_paths() {
  local candidates=(
    "${PANEL_ROOT}"
    "/var/www/featherpanel"
    "/var/www/FeatherPanel"
    "/opt/featherpanel"
    "/srv/featherpanel"
    "$HOME/featherpanel"
    "$HOME/FeatherPanel"
    "/root/FeatherPanel"
    "/root/local-feather"
    "$(pwd)/.."
    "$(pwd)"
  )
  for root in "${candidates[@]}"; do
    [[ -z "$root" || ! -d "$root" ]] && continue
    if [[ -z "$FRONTEND_DIR" ]]; then
      for f in \
        "$root/frontendv2" \
        "$root/frontend" \
        "$root/panel/frontendv2"
      do
        if [[ -f "$f/src/app/(app)/admin/vds-nodes/create/page.tsx" ]]; then
          FRONTEND_DIR="$f"
          PANEL_ROOT="${PANEL_ROOT:-$root}"
          break
        fi
      done
    fi
    if [[ -z "$BACKEND_DIR" ]]; then
      for b in "$root/backend" "$root/panel/backend"; do
        if [[ -f "$b/app/Chat/VmNode.php" || -f "$b/app/Controllers/Admin/VmNodesController.php" ]]; then
          BACKEND_DIR="$b"
          PANEL_ROOT="${PANEL_ROOT:-$root}"
          break
        fi
      done
    fi
  done
}

detect_paths

CREATE_PAGE=""
if [[ -n "$FRONTEND_DIR" ]]; then
  CREATE_PAGE="$FRONTEND_DIR/src/app/(app)/admin/vds-nodes/create/page.tsx"
fi

if [[ -z "$CREATE_PAGE" || ! -f "$CREATE_PAGE" ]]; then
  err "Could not find frontend create page.
Searched for: src/app/(app)/admin/vds-nodes/create/page.tsx
Pass explicitly:
  sudo bash ui.sh --frontend /path/to/frontendv2
  sudo bash ui.sh --panel-root /var/www/featherpanel"
fi

info "Frontend: $FRONTEND_DIR"
info "Create page: $CREATE_PAGE"
[[ -n "$BACKEND_DIR" ]] && info "Backend: $BACKEND_DIR" || warn "Backend not found (UI-only patch)"

# ── backup ──────────────────────────────────────────────────────
TS="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="${PANEL_ROOT:-/tmp}/.localnode-ui-backup-$TS"
mkdir -p "$BACKUP_DIR"
cp -a "$CREATE_PAGE" "$BACKUP_DIR/page.tsx.create.bak"
info "Backup → $BACKUP_DIR/page.tsx.create.bak"

# ── patch create page with Python (reliable) ────────────────────
python3 - "$CREATE_PAGE" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
orig = src

if "driver: 'localnode'" in src or 'LOCALNODE_UI_PATCH' in src:
    print("[ui.sh] Create page already patched — skipping TSX changes")
    sys.exit(0)

# 1) Extend form state
old_form = """    const [form, setForm] = useState({
        name: '',
        description: '',
        fqdn: '',
        location_id: '',
        scheme: 'https',
        port: 8006,
        user: '',
        token_id: '',
        secret: '',
        tls_no_verify: 'false' as 'true' | 'false',
        timeout: 60,
    });"""

new_form = """    // LOCALNODE_UI_PATCH
    const [form, setForm] = useState({
        name: '',
        description: '',
        fqdn: '',
        location_id: '',
        scheme: 'https',
        port: 8006,
        user: '',
        token_id: '',
        secret: '',
        agent_token: '',
        driver: 'proxmox' as 'proxmox' | 'localnode',
        tls_no_verify: 'false' as 'true' | 'false',
        timeout: 60,
    });"""

if old_form not in src:
    # fuzzy: insert fields before closing of useState form object
    m = re.search(
        r"(const \[form, setForm\] = useState\(\{)(.*?)(\n\s*\}\);)",
        src,
        re.S,
    )
    if not m:
        print("[ui.sh] ERROR: could not find form useState block", file=sys.stderr)
        sys.exit(2)
    block = m.group(0)
    if "driver:" not in block:
        block2 = block.replace(
            "timeout: 60,",
            "timeout: 60,\n        agent_token: '',\n        driver: 'proxmox' as 'proxmox' | 'localnode',",
        )
        if "agent_token" not in block2:
            # insert before timeout
            block2 = re.sub(
                r"(tls_no_verify:[^\n]+\n)",
                r"\1        agent_token: '',\n        driver: 'proxmox' as 'proxmox' | 'localnode',\n",
                block,
                count=1,
            )
        src = src.replace(block, "// LOCALNODE_UI_PATCH\n" + block2)
else:
    src = src.replace(old_form, new_form)

# 2) Validation: only require proxmox fields when driver is proxmox
# Replace rigid token validation if present
src2 = src
# Make token_id / secret / user validation conditional
src2 = re.sub(
    r"if \(!form\.token_id\.trim\(\)\) newErrors\.token_id = ([^;]+);",
    r"if (form.driver !== 'localnode' && !form.token_id.trim()) newErrors.token_id = \1;",
    src2,
)
src2 = re.sub(
    r"if \(!form\.secret\.trim\(\)\) newErrors\.secret = ([^;]+);",
    r"if (form.driver !== 'localnode' && !form.secret.trim()) newErrors.secret = \1;",
    src2,
)
src2 = re.sub(
    r"if \(!form\.user\.trim\(\)\) newErrors\.user = ([^;]+);",
    r"if (form.driver !== 'localnode' && !form.user.trim()) newErrors.user = \1;",
    src2,
)
# Add agent_token required for localnode (after token validations block if possible)
if "agent_token_required" not in src2 and "newErrors.agent_token" not in src2:
    src2 = re.sub(
        r"(if \(form\.driver !== 'localnode' && !form\.token_id\.trim\(\)\)[^\n]+\n)",
        r"\1        if (form.driver === 'localnode' && !form.agent_token.trim()) newErrors.agent_token = 'Agent token is required';\n",
        src2,
        count=1,
    )
src = src2

# 3) When driver switches, adjust default port
if "LOCALNODE_DRIVER_EFFECT" not in src:
    inject_effect = """
    // LOCALNODE_DRIVER_EFFECT
    useEffect(() => {
        if (form.driver === 'localnode') {
            setForm((prev) => ({
                ...prev,
                port: prev.port === 8006 ? 8444 : prev.port,
                scheme: prev.scheme === 'https' && prev.port === 8006 ? 'http' : prev.scheme,
            }));
        } else if (form.driver === 'proxmox' && form.port === 8444) {
            setForm((prev) => ({ ...prev, port: 8006, scheme: 'https' }));
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [form.driver]);
"""
    # after form baseline hook
    src = re.sub(
        r"(const \{ dirty: unsaved, restore: restoreForm \} = useFormBaseline\([^\)]*\);)",
        r"\1\n" + inject_effect,
        src,
        count=1,
    )

# 4) UI: Driver select + conditional LocalNode card
# Insert after basic details PageCard opening area is hard; inject before Proxmox card title usage
MARKER = "title={t('admin.vdsNodes.form.proxmox')}"
if MARKER in src and "LOCALNODE_DRIVER_UI" not in src:
    driver_ui = r"""
                        {/* LOCALNODE_DRIVER_UI */}
                        <PageCard title="Node driver" icon={Server}>
                            <div className='space-y-4'>
                                <div className='space-y-2'>
                                    <Label className='text-sm font-semibold'>Driver</Label>
                                    <Select
                                        value={form.driver}
                                        onChange={(e) =>
                                            setForm({
                                                ...form,
                                                driver: e.target.value as 'proxmox' | 'localnode',
                                            })
                                        }
                                    >
                                        <option value='proxmox'>Proxmox (PVE API)</option>
                                        <option value='localnode'>LocalNode (KVM / libvirt agent)</option>
                                    </Select>
                                    <p className='text-xs text-muted-foreground'>
                                        LocalNode runs on bare Ubuntu/KVM with the LocalNode agent (no Proxmox required).
                                    </p>
                                </div>
                            </div>
                        </PageCard>

                        {form.driver === 'localnode' && (
                            <PageCard title="LocalNode agent" icon={Server}>
                                <div className='space-y-6'>
                                    <div className='rounded-lg border border-amber-500/30 bg-amber-500/5 p-3 text-sm'>
                                        Install the agent on the host with <code className='text-xs'>bash local.sh</code>,
                                        then paste the generated token. Default agent port is 8444 (change if needed).
                                    </div>
                                    <div className='space-y-2'>
                                        <Label className='text-sm font-semibold'>Agent token</Label>
                                        <Input
                                            type='password'
                                            autoComplete='off'
                                            placeholder='paste token from local.sh'
                                            value={form.agent_token}
                                            onChange={(e) => setForm({ ...form, agent_token: e.target.value })}
                                            error={!!errors.agent_token}
                                        />
                                        {errors.agent_token && (
                                            <p className='mt-1 text-xs font-medium text-red-500'>{errors.agent_token}</p>
                                        )}
                                    </div>
                                </div>
                            </PageCard>
                        )}

                        {form.driver === 'proxmox' && (
"""
    # Wrap existing Proxmox PageCard: find the PageCard with proxmox title and close before Network section roughly
    idx = src.find(MARKER)
    # find start of that PageCard — walk back to <PageCard
    start = src.rfind("<PageCard", 0, idx)
    if start == -1:
        print("[ui.sh] WARN: could not wrap Proxmox card", file=sys.stderr)
    else:
        # Insert driver UI before Proxmox card and open conditional
        src = src[:start] + driver_ui + src[start:]
        # Close the conditional after this PageCard ends — find matching close after start
        # Look for next sibling pattern: after proxmox card, often Network card
        # Simple approach: after first </PageCard> following the proxmox title
        after = src.find(MARKER)
        close = src.find("</PageCard>", after)
        if close != -1:
            close_end = close + len("</PageCard>")
            src = src[:close_end] + "\n                        )}\n" + src[close_end:]

# 5) Header description tweak
src = src.replace(
    "Connect a new Proxmox hypervisor to FeatherPanel using a PVE API token.",
    "Connect a Proxmox hypervisor or a LocalNode (KVM agent) to FeatherPanel.",
)

if src == orig:
    print("[ui.sh] ERROR: no changes applied — form layout may differ from expected upstream", file=sys.stderr)
    sys.exit(3)

path.write_text(src, encoding="utf-8")
print(f"[ui.sh] Patched {path}")
PY

info "Create page patched"

# ── optional: edit page connection tab if present ───────────────
EDIT_CONN="$FRONTEND_DIR/src/app/(app)/admin/vds-nodes/[id]/edit/ConnectionTab.tsx"
if [[ -f "$EDIT_CONN" ]] && ! grep -q 'LOCALNODE_UI_PATCH' "$EDIT_CONN" 2>/dev/null; then
  cp -a "$EDIT_CONN" "$BACKUP_DIR/ConnectionTab.tsx.bak"
  warn "Edit ConnectionTab exists — manual LocalNode fields recommended; create page is the main entry."
fi

# ── backend VmNode allowed fields ───────────────────────────────
if [[ "$SKIP_BACKEND" -eq 0 && -n "$BACKEND_DIR" ]]; then
  VMNODE="$BACKEND_DIR/app/Chat/VmNode.php"
  if [[ -f "$VMNODE" ]]; then
    cp -a "$VMNODE" "$BACKUP_DIR/VmNode.php.bak"
    if ! grep -q "'driver'" "$VMNODE"; then
      python3 - "$VMNODE" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
# insert into allowedFields array after 'name' or at end before ];
if "'driver'" in s:
    print("VmNode already has driver")
    sys.exit(0)
s2, n = re.subn(
    r"('name',)",
    r"\1\n        'driver',\n        'agent_token',\n        'host_cpu_threads',\n        'host_memory_mb',\n        'host_disk_gb',\n        'kvm_available',\n        'last_heartbeat_at',",
    s,
    count=1,
)
if n:
    p.write_text(s2, encoding="utf-8")
    print("Patched VmNode.php allowedFields")
else:
    print("WARN: could not patch allowedFields", file=sys.stderr)
PY
      info "VmNode.php allowedFields updated"
    else
      info "VmNode.php already has driver field"
    fi
  fi

  # Copy LocalNode services if present next to this script
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PKG_BACKEND="$(cd "$SCRIPT_DIR/../panel/backend" 2>/dev/null && pwd || true)"
  if [[ -n "$PKG_BACKEND" && -d "$PKG_BACKEND" ]]; then
    mkdir -p "$BACKEND_DIR/app/Services" "$BACKEND_DIR/app/Controllers/Admin"
    if [[ -f "$PKG_BACKEND/Services/LocalNodeClient.php" ]]; then
      cp -a "$PKG_BACKEND/Services/LocalNodeClient.php" "$BACKEND_DIR/app/Services/"
      info "Installed LocalNodeClient.php"
    fi
    if [[ -f "$PKG_BACKEND/Controllers/LocalNodeController.php" ]]; then
      cp -a "$PKG_BACKEND/Controllers/LocalNodeController.php" "$BACKEND_DIR/app/Controllers/Admin/"
      info "Installed LocalNodeController.php"
    fi
  fi

  # Migration
  MIG_SRC="$SCRIPT_DIR/../panel/migrations/2026-11-01.00.00-localnode.sql"
  MIG_DST_DIRS=(
    "$BACKEND_DIR/storage/migrations"
    "$PANEL_ROOT/backend/storage/migrations"
  )
  if [[ -f "$MIG_SRC" ]]; then
    for d in "${MIG_DST_DIRS[@]}"; do
      if [[ -d "$d" ]]; then
        cp -a "$MIG_SRC" "$d/"
        info "Copied migration → $d/"
        break
      fi
    done
  fi
fi

# ── rebuild frontend ────────────────────────────────────────────
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  if [[ -f "$FRONTEND_DIR/package.json" ]]; then
    info "Building frontend (this can take a few minutes)..."
    (
      cd "$FRONTEND_DIR"
      if [[ -f yarn.lock ]]; then
        yarn build || npm run build || warn "Frontend build failed — run manually"
      else
        npm run build || warn "Frontend build failed — run manually: cd $FRONTEND_DIR && npm run build"
      fi
    ) || warn "Build step had errors"
  else
    warn "No package.json in frontend — skip build"
  fi
else
  warn "Skipped frontend build (--skip-build)"
fi

echo
info "=============================================="
info " LocalNode UI patch applied"
info "=============================================="
echo "  Create page : $CREATE_PAGE"
echo "  Backup      : $BACKUP_DIR"
echo
echo "  Open Admin → VDS → Nodes → Create"
echo "  Choose Driver: LocalNode (KVM / libvirt agent)"
echo "  Port: 8444  |  paste agent token from local.sh"
echo
echo "  Run DB migration if not auto-applied, then restart panel PHP/Caddy as usual."
echo "  Restore UI:  cp $BACKUP_DIR/page.tsx.create.bak \"$CREATE_PAGE\""
echo
info "Done."
