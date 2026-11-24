# Test helper: what the fake host's login is now (user from config, the two secrets' values: fake test values only).
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class Peek {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct C { public int F; public int T; public string N; public string Cm; public long L; public int S; public IntPtr B; public int P; public int A; public IntPtr At; public string Al; public string U; }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredReadW(string t, int ty, int f, out IntPtr c);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredDeleteW(string t, int ty, int f);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
  public static string R(string t) { IntPtr p; if (!CredReadW(t, 1, 0, out p)) return "-"; try { var c = (C)Marshal.PtrToStructure(p, typeof(C)); var b = new byte[c.S]; Marshal.Copy(c.B, b, 0, b.Length); return Encoding.UTF8.GetString(b) + " (persist " + c.P + ", user '" + c.U + "')"; } finally { CredFree(p); } }
  public static void D(string t) { CredDeleteW(t, 1, 0); }
}
"@
$h = 'fake-test.invalid'
if ($args[0] -eq 'clean') { [Peek]::D("glab:${h}:token:"); [Peek]::D("glab:${h}:oauth2_refresh_token:"); 'keyring entries of the fake host deleted'; return }
$cfg = [IO.File]::ReadAllText((Join-Path $env:GLAB_CONFIG_DIR 'config.yml'))
$u = if ($cfg -match '(?ms)^    fake-test\.invalid:\s*$(.*?)(?=^    \S|^\S|\z)') { if ($Matches[1] -match '(?m)^ {8}user:\s*(\S*)') { $Matches[1] } else { '?' } } else { '?' }
"   live: user=$u token=" + [Peek]::R("glab:${h}:token:") + " refresh=" + [Peek]::R("glab:${h}:oauth2_refresh_token:")
