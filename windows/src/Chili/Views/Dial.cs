using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace Chili.Views;

/// <summary>A small tachometer: 240° scale, coloured arc up to the value and a needle,
/// percentage under the hub and a label below. Same drawing as the macOS Dial.</summary>
public sealed class Dial : UserControl
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(Dial), new PropertyMetadata(0.0, (d, _) => ((Dial)d).Redraw()));
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(Dial), new PropertyMetadata("", (d, _) => ((Dial)d).Redraw()));

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }

    private const double Size = 42, Sweep = 240, Start = 150;   // degrees, 0 = 3 o'clock, clockwise
    private readonly Path track = new() { StrokeThickness = 4, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Path arc = new() { StrokeThickness = 4, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Path ticks = new() { StrokeThickness = 1 };
    private readonly Path needle = new() { StrokeThickness = 1.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Ellipse hub = new() { Width = 4, Height = 4 };
    private readonly TextBlock percent = new() { FontSize = 8, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Width = Size, TextAlignment = TextAlignment.Center };
    private readonly TextBlock caption = new() { FontSize = 8, Width = Size, TextAlignment = TextAlignment.Center };

    public Dial()
    {
        var canvas = new Canvas { Width = Size, Height = Size + 12 };
        foreach (var e in new UIElement[] { track, arc, ticks, needle, hub, percent, caption }) canvas.Children.Add(e);
        Canvas.SetLeft(hub, Size / 2 - 2);
        Canvas.SetTop(hub, Size / 2 - 2);
        Canvas.SetTop(percent, Size / 2 + 9);
        Canvas.SetTop(caption, Size + 1);
        Content = canvas;
        ActualThemeChanged += (_, _) => Redraw();
        Loaded += (_, _) => Redraw();
    }

    private static Point At(double fraction, double radius)
    {
        double a = (Start + Sweep * fraction) * Math.PI / 180;
        return new Point(Size / 2 + Math.Cos(a) * radius, Size / 2 + Math.Sin(a) * radius);
    }

    private static Geometry Arc(double from, double to)
    {
        double r = Size / 2 - 3;
        var figure = new PathFigure { StartPoint = At(from, r), IsClosed = false };
        if (to - from > 0.0005)
            figure.Segments.Add(new ArcSegment
            {
                Point = At(to, r), Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise,
                IsLargeArc = Sweep * (to - from) > 180,
            });
        else
            figure.Segments.Add(new LineSegment { Point = At(from, r) });
        var g = new PathGeometry();
        g.Figures.Add(figure);
        return g;
    }

    private static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    private void Redraw()
    {
        double v = Math.Clamp(Value, 0, 1);
        var secondary = Res("TextFillColorSecondaryBrush");
        var primary = Res("TextFillColorPrimaryBrush");

        track.Data = Arc(0, 1);
        track.Stroke = Res("ControlStrongFillColorDisabledBrush");
        arc.Data = Arc(0, v);
        arc.Stroke = v > 0.9 ? Res("DangerBrush") : v > 0.7 ? Res("WarningBrush") : Res("AccentFillColorDefaultBrush");

        var tickGeometry = new GeometryGroup();
        for (int i = 0; i < 5; i++)
            tickGeometry.Children.Add(new LineGeometry { StartPoint = At(i / 4.0, Size / 2 - 7), EndPoint = At(i / 4.0, Size / 2 - 9.5) });
        ticks.Data = tickGeometry;
        ticks.Stroke = secondary;

        needle.Data = new LineGeometry { StartPoint = new Point(Size / 2, Size / 2), EndPoint = At(v, Size / 2 - 9) };
        needle.Stroke = primary;
        hub.Fill = primary;
        percent.Text = $"{(int)Math.Round(v * 100)}%";
        percent.Foreground = primary;
        caption.Text = Label;
        caption.Foreground = secondary;
    }
}
