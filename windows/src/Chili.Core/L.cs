using System.Globalization;
using System.Reflection;
using System.Text;

namespace Chili.Core;

/// <summary>
/// Localization with the macOS conventions: the key is the English text, translations come
/// from Apple-style .strings files ("key" = "value";) and formats use %@ / %d placeholders.
/// </summary>
public static class L
{
    private static Dictionary<string, string> table = Load(CultureInfo.CurrentUICulture);

    /// <summary>Switches language (tests, demo screenshots). Normally follows the UI culture.</summary>
    public static void Use(CultureInfo culture) => table = Load(culture);

    public static bool IsTranslated(string english) => table.ContainsKey(english);

    /// <summary>The translation of an English string, or the string itself.</summary>
    public static string T(string english) => table.TryGetValue(english, out var t) ? t : english;

    /// <summary>Translates and fills %@, %d, %lld… placeholders in order.</summary>
    public static string F(string english, params object?[] args) => Format(T(english), args);

    public static string Format(string format, params object?[] args)
    {
        var sb = new StringBuilder();
        int next = 0;
        for (int i = 0; i < format.Length; i++)
        {
            char c = format[i];
            if (c != '%' || i + 1 >= format.Length) { sb.Append(c); continue; }
            if (format[i + 1] == '%') { sb.Append('%'); i++; continue; }
            int j = i + 1;
            while (j < format.Length && "l".Contains(format[j])) j++;
            if (j < format.Length && "@dis".Contains(format[j]))
            {
                var arg = next < args.Length ? args[next++] : null;
                sb.Append(Convert.ToString(arg, CultureInfo.CurrentCulture));
                i = j;
            }
            else sb.Append(c);
        }
        return sb.ToString();
    }

    private static Dictionary<string, string> Load(CultureInfo culture)
    {
        var result = new Dictionary<string, string>();
        if (culture.TwoLetterISOLanguageName != "it") return result;
        foreach (var name in new[] { "it.strings", "it.windows.strings" })
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
            if (stream is null) continue;
            using var reader = new StreamReader(stream, Encoding.UTF8);
            foreach (var (k, v) in ParseStrings(reader.ReadToEnd())) result[k] = v;
        }
        return result;
    }

    /// <summary>Parses an Apple .strings file: "key" = "value"; with /* */ and // comments.</summary>
    public static IEnumerable<(string Key, string Value)> ParseStrings(string text)
    {
        int i = 0;
        string? Quoted()
        {
            if (i >= text.Length || text[i] != '"') return null;
            var sb = new StringBuilder();
            for (i++; i < text.Length; i++)
            {
                char c = text[i];
                if (c == '"') { i++; return sb.ToString(); }
                if (c == '\\' && i + 1 < text.Length)
                {
                    char e = text[++i];
                    sb.Append(e switch { 'n' => '\n', 't' => '\t', 'r' => '\r', _ => e });
                }
                else sb.Append(c);
            }
            return null;
        }
        void Skip()
        {
            while (i < text.Length)
            {
                if (char.IsWhiteSpace(text[i])) i++;
                else if (text.AsSpan(i).StartsWith("/*"))
                {
                    int end = text.IndexOf("*/", i + 2, StringComparison.Ordinal);
                    i = end < 0 ? text.Length : end + 2;
                }
                else if (text.AsSpan(i).StartsWith("//"))
                {
                    int end = text.IndexOf('\n', i);
                    i = end < 0 ? text.Length : end + 1;
                }
                else break;
            }
        }
        while (true)
        {
            Skip();
            var key = Quoted();
            if (key is null) yield break;
            Skip();
            if (i >= text.Length || text[i] != '=') yield break;
            i++;
            Skip();
            var value = Quoted();
            if (value is null) yield break;
            Skip();
            if (i < text.Length && text[i] == ';') i++;
            yield return (key, value);
        }
    }
}
