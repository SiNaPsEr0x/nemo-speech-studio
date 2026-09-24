"""Backport C++14 compatible branches to the pinned mlx-swift 0.31.6 Metal source.

The upstream generated Steel headers use C++17's `if constexpr`, although
Xcode compiles Metal as C++14. Reject source drift so dependency updates never
silently omit the actual source fix.
"""
from pathlib import Path
import stat
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f"Expected one upstream fragment in {path}: {old[:60]!r}")
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    path.write_text(source.replace(old, new))


root = Path(sys.argv[1]) / "SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel"
replace_once(
    root / "utils/integral_constant.h",
    """template <int start, int stop, int step, typename F>
constexpr void const_for_loop(F f) {
  if constexpr (start < stop) {
    constexpr auto idx = Int<start>{};
    f(idx);
    const_for_loop<start + step, stop, step, F>(f);
  }
}
""",
    """// Metal uses C++14: choose the terminating overload at compile time.
template <int start, int stop, int step, typename F>
constexpr metal::enable_if_t<(start >= stop), void> const_for_loop(F) {}

template <int start, int stop, int step, typename F>
constexpr metal::enable_if_t<(start < stop), void> const_for_loop(F f) {
  constexpr auto idx = Int<start>{};
  f(idx);
  const_for_loop<start + step, stop, step, F>(f);
}
""",
)
attention = root / "attn/kernels/steel_attention.h"
replace_once(attention, "if constexpr (is_bool) {", "if (is_bool) {")
source = attention.read_text()
if source.count("if constexpr (BD == 128) {") != 2:
    raise RuntimeError("Unexpected Steel attention barrier source")
attention.chmod(attention.stat().st_mode | stat.S_IWUSR)
attention.write_text(source.replace("if constexpr (BD == 128) {", "if (BD == 128) {"))
print("Patched four upstream C++17 branches to valid Metal C++14 branches")
