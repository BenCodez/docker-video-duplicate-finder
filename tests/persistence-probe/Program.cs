using VDF.Core.Utils;
using System.Reflection;

// These are the actual patched CoreUtils methods, including the path used when
// DOTNET_RUNNING_IN_CONTAINER disables desktop portable mode.
Environment.SetEnvironmentVariable("DOTNET_RUNNING_IN_CONTAINER", "true");
Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", "/tmp/ephemeral-config");
Environment.SetEnvironmentVariable("XDG_STATE_HOME", "/tmp/ephemeral-state");
var folders = new[] {
    CoreUtils.CurrentFolder, CoreUtils.SettingsFolder, CoreUtils.StateFolder,
    CoreUtils.GetDefaultSettingsFolder(), CoreUtils.GetDefaultStateFolder(),
    CoreUtils.ResolveDatabaseFolder(null), CoreUtils.ResolveDatabaseFolder("/missing-vdf-test-folder")
};
if (folders.Any(folder => folder != "/config"))
    throw new InvalidOperationException("A default application state path escaped /config.");
if (CoreUtils.ResolveDatabaseFolder(Path.GetTempPath()) != Path.GetTempPath())
    throw new InvalidOperationException("An explicit existing database folder was not respected.");
Console.WriteLine("PASS: every default application settings/state/database path is /config.");
var revision = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
    .Single(attribute => attribute.Key == "CommitId").Value;
if (revision is null || revision.Length != 40 || !revision.All(char.IsAsciiHexDigit))
    throw new InvalidOperationException("Source archive did not preserve the full pinned application revision.");
Console.WriteLine("PASS: source archive assembly metadata preserves the full pinned commit.");
