using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using Nuke.Common;
using Nuke.Common.Execution;
using Nuke.Common.Git;
using Nuke.Common.IO;
using Nuke.Common.ProjectModel;
using Nuke.Common.Tooling;
using Nuke.Common.Tools.DotNet;
using Nuke.Common.Tools.MSBuild;
using Serilog;

[UnsetVisualStudioEnvironmentVariables]
public class DalamudBuild : NukeBuild
{
    static DalamudBuild()
    {
        try
        {
            // Try to locate MSBuild using vswhere (recommended) and fall back to common paths.
            var msbuild = GetMSBuildFromVsWhere() ?? GetMSBuildFromCommonPaths();
            if (!string.IsNullOrEmpty(msbuild) && File.Exists(msbuild))
                MSBuildTasks.MSBuildPath = msbuild;
        }
        catch
        {
            // Swallow any exceptions — failing to detect MSBuild should not crash the build script.
        }
    }

    private static string GetMSBuildFromVsWhere()
    {
        try
        {
            var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            var vswhere = Path.Combine(programFilesX86, "Microsoft Visual Studio", "Installer", "vswhere.exe");
            if (!File.Exists(vswhere))
                return null;

            var psi = new ProcessStartInfo(vswhere, "-latest -products * -requires Microsoft.Component.MSBuild -property installationPath")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc == null)
                return null;

            var output = proc.StandardOutput.ReadToEnd().Trim();
            //proc.WaitForExit(3000);
            if (string.IsNullOrEmpty(output))
                return null;

            var candidate = Path.Combine(output, "MSBuild", "Current", "Bin", "MSBuild.exe");
            return File.Exists(candidate) ? candidate : null;
        }
        catch
        {
            return null;
        }
    }

    private static string GetMSBuildFromCommonPaths()
    {
        var candidates = new[]
        {
            @"C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
            @"C:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin\MSBuild.exe",
            @"C:\Program Files\Microsoft Visual Studio\17\Community\MSBuild\Current\Bin\MSBuild.exe",
            @"C:\Program Files\Microsoft Visual Studio\17\Professional\MSBuild\Current\Bin\MSBuild.exe",
            @"C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        };

        foreach (var c in candidates)
            if (File.Exists(c))
                return c;

        return null;
    }
    /// Support plugins are available for:
    ///   - Microsoft VisualStudio     https://nuke.build/visualstudio
    ///   - JetBrains ReSharper        https://nuke.build/resharper
    ///   - JetBrains Rider            https://nuke.build/rider
    ///   - Microsoft VSCode           https://nuke.build/vscode

    public static int Main() => Execute<DalamudBuild>(x => x.Compile);

    [Parameter("Configuration to build - Default is 'Debug' (local) or 'Release' (server)")]
    readonly Configuration Configuration = IsLocalBuild ? Configuration.Debug : Configuration.Release;

    [Parameter("Whether we are building for documentation - emits generated files")]
    readonly bool IsDocsBuild = false;

    [Solution] Solution Solution;
    [GitRepository] GitRepository GitRepository;

    AbsolutePath DalamudProjectDir => RootDirectory / "Dalamud";
    AbsolutePath DalamudProjectFile => DalamudProjectDir / "Dalamud.csproj";

    AbsolutePath DalamudBootProjectDir => RootDirectory / "Dalamud.Boot";
    AbsolutePath DalamudBootProjectFile => DalamudBootProjectDir / "Dalamud.Boot.vcxproj";
    
    AbsolutePath DalamudCrashHandlerProjectDir => RootDirectory / "DalamudCrashHandler";
    AbsolutePath DalamudCrashHandlerProjectFile => DalamudCrashHandlerProjectDir / "DalamudCrashHandler.vcxproj";

    AbsolutePath InjectorProjectDir => RootDirectory / "Dalamud.Injector";
    AbsolutePath InjectorProjectFile => InjectorProjectDir / "Dalamud.Injector.csproj";
    
    AbsolutePath TestProjectDir => RootDirectory / "Dalamud.Test";
    AbsolutePath TestProjectFile => TestProjectDir / "Dalamud.Test.csproj";

    AbsolutePath ExternalsDir => RootDirectory / "external";
    AbsolutePath CImGuiDir => ExternalsDir / "cimgui";
    AbsolutePath CImGuiProjectFile => CImGuiDir / "cimgui.vcxproj";
    AbsolutePath CImPlotDir => ExternalsDir / "cimplot";
    AbsolutePath CImPlotProjectFile => CImPlotDir / "cimplot.vcxproj";
    AbsolutePath CImGuizmoDir => ExternalsDir / "cimguizmo";
    AbsolutePath CImGuizmoProjectFile => CImGuizmoDir / "cimguizmo.vcxproj";

    AbsolutePath ArtifactsDirectory => RootDirectory / "bin" / Configuration;

    private static AbsolutePath LibraryDirectory => RootDirectory / "lib";

    private static Dictionary<string, string> EnvironmentVariables => new(EnvironmentInfo.Variables);

    private static string ConsoleTemplate => "{Message:l}{NewLine}{Exception}";
    private static bool IsCIBuild => Environment.GetEnvironmentVariable("CI") == "true";

    Target Restore => _ => _
        .Executes(() =>
        {
            DotNetTasks.DotNetRestore(s => s
                .SetProjectFile(Solution));
        });

    Target CompileCImGui => _ => _
        .Executes(() =>
        {
            // Not necessary, and does not build on Linux
            if (IsDocsBuild)
                return;

            MSBuildTasks.MSBuild(s => s
                .SetTargetPath(CImGuiProjectFile)
                .SetConfiguration(Configuration)
                .SetTargetPlatform(MSBuildTargetPlatform.x64));
        });

    Target CompileCImPlot => _ => _
        .Executes(() =>
        {
            // Not necessary, and does not build on Linux
            if (IsDocsBuild)
                return;

            MSBuildTasks.MSBuild(s => s
                .SetTargetPath(CImPlotProjectFile)
                .SetConfiguration(Configuration)
                .SetTargetPlatform(MSBuildTargetPlatform.x64));
        });

    Target CompileCImGuizmo => _ => _
        .Executes(() =>
        {
            // Not necessary, and does not build on Linux
            if (IsDocsBuild)
                return;

            MSBuildTasks.MSBuild(s => s
                .SetTargetPath(CImGuizmoProjectFile)
                .SetConfiguration(Configuration)
                .SetTargetPlatform(MSBuildTargetPlatform.x64));
        });

    Target CompileImGuiNatives => _ => _
        .DependsOn(CompileCImGui)
        .DependsOn(CompileCImPlot)
        .DependsOn(CompileCImGuizmo);

    Target CompileDalamud => _ => _
        .DependsOn(Restore)
        .DependsOn(CompileImGuiNatives)
        .Executes(() =>
        {
            DotNetTasks.DotNetBuild(s =>
            {
                s = s
                       .SetProjectFile(DalamudProjectFile)
                       .SetConfiguration(Configuration)
                       .EnableNoRestore();
                if (IsCIBuild)
                {
                    s = s
                        .SetProcessAdditionalArguments("/clp:NoSummary"); // Disable MSBuild summary on CI builds
                }
                // We need to emit compiler generated files for the docs build, since docfx can't run generators directly
                // TODO: This fails every build after this because of redefinitions...

                // if (IsDocsBuild)
                // { 
                //     Log.Warning("Building for documentation, emitting compiler generated files. This can cause issues on Windows due to path-length limitations");
                //     s = s
                //         .SetProperty("IsDocsBuild", "true");
                // }
                return s;
            });
        });

    Target CompileDalamudBoot => _ => _
        .Executes(() =>
        {
            MSBuildTasks.MSBuild(s => s
                .SetTargetPath(DalamudBootProjectFile)
                .SetConfiguration(Configuration));
        });
    
    Target CompileDalamudCrashHandler => _ => _
        .Executes(() =>
        {
            MSBuildTasks.MSBuild(s => s
                                      .SetTargetPath(DalamudCrashHandlerProjectFile)
                                      .SetConfiguration(Configuration));
        });

    Target CompileInjector => _ => _
        .DependsOn(Restore)
        .Executes(() =>
        {
            DotNetTasks.DotNetBuild(s => s
                .SetProjectFile(InjectorProjectFile)
                .SetConfiguration(Configuration)
                .EnableNoRestore());
        });

    Target SetCILogging => _ => _
        .DependentFor(Compile)
        .OnlyWhenStatic(() => IsCIBuild)
        .Executes(() =>
        {
            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Debug()
                .WriteTo.Console(outputTemplate: ConsoleTemplate)
                .CreateLogger();
        });

    Target Compile => _ => _
    .DependsOn(CompileDalamud)
    .DependsOn(CompileDalamudBoot)
    .DependsOn(CompileDalamudCrashHandler)
    .DependsOn(CompileInjector)
    ;

    Target CI => _ => _
        .DependsOn(Compile)
        .Triggers(Test);

    Target Test => _ => _
        .DependsOn(Compile)
        .Executes(() =>
        {
            DotNetTasks.DotNetTest(s => s
                .SetProjectFile(TestProjectFile)
                .SetConfiguration(Configuration)
                .AddProperty("WarningLevel", "0")
                .EnableNoRestore());
        });

    Target Clean => _ => _
        .Executes(() =>
        {
            MSBuildTasks.MSBuild(s => s
                .SetProjectFile(CImGuiProjectFile)
                .SetConfiguration(Configuration)
                .SetTargets("Clean"));

            MSBuildTasks.MSBuild(s => s
                .SetProjectFile(CImPlotProjectFile)
                .SetConfiguration(Configuration)
                .SetTargets("Clean"));

            MSBuildTasks.MSBuild(s => s
                .SetProjectFile(CImGuizmoProjectFile)
                .SetConfiguration(Configuration)
                .SetTargets("Clean"));

            DotNetTasks.DotNetClean(s => s
                .SetProject(DalamudProjectFile)
                .SetConfiguration(Configuration));

            MSBuildTasks.MSBuild(s => s
                .SetProjectFile(DalamudBootProjectFile)
                .SetConfiguration(Configuration)
                .SetTargets("Clean"));
            
            MSBuildTasks.MSBuild(s => s
                .SetProjectFile(DalamudCrashHandlerProjectFile)
                .SetConfiguration(Configuration)
                .SetTargets("Clean"));

            DotNetTasks.DotNetClean(s => s
                .SetProject(InjectorProjectFile)
                .SetConfiguration(Configuration));

            ArtifactsDirectory.CreateOrCleanDirectory();
        });
}
