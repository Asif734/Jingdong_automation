using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace Grozziie.ModelTester.Launcher;

internal static class Program
{
    private static Process? child;

    private static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        var root = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var python = Path.Combine(root, "runtime", "python.exe");
        var server = Path.Combine(root, "app", "server.py");
        var logDirectory = Path.Combine(root, "data", "logs");
        Directory.CreateDirectory(logDirectory);
        var logPath = Path.Combine(logDirectory, "launcher.log");
        if (!File.Exists(python) || !File.Exists(server))
        {
            Console.Error.WriteLine($"启动资源不完整。请重新解压安装包。\n日志目录：{logDirectory}");
            return 2;
        }
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
        var start = new ProcessStartInfo(python)
        {
            WorkingDirectory = root,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        start.ArgumentList.Add("-m"); start.ArgumentList.Add("app.server");
        start.ArgumentList.Add("--root"); start.ArgumentList.Add(root);
        start.ArgumentList.Add("--port"); start.ArgumentList.Add("0");
        start.ArgumentList.Add("--token"); start.ArgumentList.Add(token);
        child = new Process { StartInfo = start, EnableRaisingEvents = true };
        Task? stderrDrain = null;
        Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; StopChild(); };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => StopChild();
        try
        {
            child.Start();
            stderrDrain = DrainAsync(child.StandardError, logPath);
            var readyLine = await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30));
            if (readyLine is null) throw new InvalidOperationException("后端未报告就绪状态");
            await File.AppendAllTextAsync(logPath, readyLine + Environment.NewLine);
            using var ready = JsonDocument.Parse(readyLine);
            var port = ready.RootElement.GetProperty("port").GetInt32();
            var url = $"http://127.0.0.1:{port}/";
            _ = DrainAsync(child.StandardOutput, logPath);
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (true)
            {
                try { if ((await http.GetAsync(url + "api/health")).IsSuccessStatusCode) break; }
                catch (HttpRequestException) { }
                if (DateTime.UtcNow >= deadline) throw new TimeoutException("本地服务健康检查超时");
                await Task.Delay(150);
            }
            if (!args.Contains("--no-browser"))
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            Console.WriteLine("格志客服模型测试器已启动。关闭此窗口即可停止。\n" + url);
            await child.WaitForExitAsync();
            return child.ExitCode;
        }
        catch (Exception error)
        {
            StopChild();
            if (stderrDrain is not null)
            {
                try { await stderrDrain.WaitAsync(TimeSpan.FromSeconds(2)); }
                catch { }
            }
            await File.AppendAllTextAsync(logPath, error + Environment.NewLine);
            Console.Error.WriteLine($"启动失败：{error.Message}\n日志：{logPath}");
            return 1;
        }
    }

    private static async Task DrainAsync(StreamReader reader, string logPath)
    {
        while (await reader.ReadLineAsync() is { } line)
            await File.AppendAllTextAsync(logPath, line + Environment.NewLine);
    }

    private static void StopChild()
    {
        try { if (child is { HasExited: false }) child.Kill(entireProcessTree: true); }
        catch { }
    }
}
