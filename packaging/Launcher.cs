using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("ChatGPT Switcher")]
[assembly: AssemblyProduct("ChatGPT Switcher")]
[assembly: AssemblyDescription("Windows account switcher by Exyywtf")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Exyywtf. Includes MIT-licensed work by Alyawmu.")]
[assembly: AssemblyVersion("1.6.1.0")]
[assembly: AssemblyFileVersion("1.6.1.0")]
static class Launcher {
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [STAThread]
    static int Main(string[] args) {
        bool commandLine = args.Length > 0;
        IntPtr output=GetStdHandle(-11);
        if(commandLine && (output==IntPtr.Zero || output==new IntPtr(-1))) AttachConsole(0xFFFFFFFF);
        if(commandLine) {
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(),new UTF8Encoding(false)) { AutoFlush=true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(),new UTF8Encoding(false)) { AutoFlush=true });
        }
        try {
            if(args.Length == 1 && args[0] == "--license") {
                Console.Write(Encoding.UTF8.GetString(Resource("LICENSE")));
                return 0;
            }
            string localData=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if(String.IsNullOrEmpty(localData)) localData=Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if(String.IsNullOrEmpty(localData)) throw new IOException("Windows could not locate your local application data folder.");
            string folder=Path.GetFullPath(Path.Combine(localData,"ChatGPTSwitcher","app"));
            using(var mutex = new Mutex(false, @"Local\Exyywtf.ChatGPTSwitcher.Extract")) {
                bool acquired;
                try { acquired=mutex.WaitOne(TimeSpan.FromSeconds(30)); }
                catch(AbandonedMutexException) { acquired=true; }
                if(!acquired) throw new IOException("Another copy is updating the launcher. Try again.");
                try {
                    Directory.CreateDirectory(folder);
                    Extract(folder,"ChatGPT-Switcher.ps1","ChatGPT-Switcher.ps1");
                    Extract(folder,"ChatGPT-Switcher.ico","ChatGPT-Switcher.ico");
                    Extract(folder,"LICENSE","LICENSE");
                } finally { mutex.ReleaseMutex(); }
            }
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            var arguments = new StringBuilder("-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
            arguments.Append(Quote(Path.Combine(folder,"ChatGPT-Switcher.ps1")));
            foreach(string arg in args) arguments.Append(" ").Append(Quote(arg));
            var start = new ProcessStartInfo(powershell,arguments.ToString()) {
                UseShellExecute=false, CreateNoWindow=true, WorkingDirectory=folder
            };
            if(commandLine) {
                start.RedirectStandardOutput=true;
                start.RedirectStandardError=true;
                start.StandardOutputEncoding=Encoding.UTF8;
                start.StandardErrorEncoding=Encoding.UTF8;
            }
            using(var process=Process.Start(start)) {
                if(commandLine) {
                    process.OutputDataReceived += delegate(object sender,DataReceivedEventArgs e) { if(e.Data!=null) Console.WriteLine(e.Data); };
                    process.ErrorDataReceived += delegate(object sender,DataReceivedEventArgs e) { if(e.Data!=null) Console.Error.WriteLine(e.Data); };
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                }
                process.WaitForExit();
                return process.ExitCode;
            }
        } catch(Exception e) {
            if(commandLine) Console.Error.WriteLine("ChatGPT Switcher: " + e.Message);
            else MessageBox.Show(e.Message,"Could not start ChatGPT Switcher",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
    static byte[] Resource(string name) {
        using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
            if(stream==null) throw new IOException("A required application resource is missing.");
            using(var memory=new MemoryStream()) { stream.CopyTo(memory); return memory.ToArray(); }
        }
    }
    static void Extract(string folder,string name,string resource) {
        string target=Path.Combine(folder,name);
        byte[] bytes=Resource(resource);
        if(File.Exists(target)) {
            using(var sha=SHA256.Create()) {
                if(Convert.ToBase64String(sha.ComputeHash(File.ReadAllBytes(target))) ==
                   Convert.ToBase64String(sha.ComputeHash(bytes))) return;
            }
        }
        string temporary=target+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            File.WriteAllBytes(temporary,bytes);
            if(File.Exists(target)) File.Replace(temporary,target,null);
            else File.Move(temporary,target);
        } finally { if(File.Exists(temporary)) File.Delete(temporary); }
    }
    static string Quote(string value) {
        var quoted=new StringBuilder("\"");
        int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='"') { quoted.Append('\\',slashes*2+1).Append(c); slashes=0; continue; }
            quoted.Append('\\',slashes).Append(c); slashes=0;
        }
        quoted.Append('\\',slashes*2).Append('"');
        return quoted.ToString();
    }
}
