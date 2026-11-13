#Requires -Version 5.1
<#
.SYNOPSIS
  ChatGPT Switcher: an English, dark-mode Windows account launcher.
.DESCRIPTION
  Opens accounts using their existing Electron data and CODEX_HOME. Isolated
  accounts can run together. Shared-project accounts use the real Codex home
  and preserve the existing authentication backup and switching behavior.

  No arguments: open the picker. Other options:
    -Launch Work       Open an account by ID or display name
    -Add Work          Add an isolated account and desktop shortcut
    -Add Work -Shared  Add an account that shares local projects and chats
    -SaveAuth Work     Save the current login for a shared-project account
    -Remove Work       Remove an account and its local data
    -List              List accounts
    -Setup             Create Desktop and Start menu shortcuts
    -Tray              Run in the notification area
    -AutoStartTray     Start tray mode at Windows sign-in
    -Diagnose          Print environment diagnostics
    -Version           Print the application version

  Data: %USERPROFILE%\ChatGPT-Accounts\<account ID>\{electron,codex}
  Open the .cmd launcher for STA mode. CLI switches and storage are unchanged.
#>
param(
  [string]$Launch,
  [string]$Add,
  [string]$Remove,
  [switch]$List,
  [switch]$Setup,
  [switch]$Tray,
  [switch]$AutoStartTray,
  [switch]$Diagnose,
  [switch]$NoShortcut,
  [switch]$Version,
  [switch]$Shared,
  [string]$SaveAuth
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:AppVersion = '1.6.0'
$script:AppId      = 'Alyawmu.ChatGPTSwitcher'   # taskbar grouping + jump list identity
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:Root       = Join-Path $env:USERPROFILE 'ChatGPT-Accounts'
$script:ConfigPath = Join-Path $script:Root 'accounts.json'
$script:LogPath    = Join-Path $script:Root 'switcher.log'
$script:MainId     = '__main__'
$script:MainLabel  = 'Main (original app session)'
$script:Palette    = @('#4285F4','#34A853','#EA4335','#F9AB00','#A142F4','#F538A0','#12B5CB','#FF6D01')
$script:AppCache   = $null
$script:Gui        = $false

# ------------------------------------------------------------------ 共通

function Write-Log {
  param([string]$Message)
  try {
    New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    Add-Content -Path $script:LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
  } catch {}
}

function Ensure-Gui {
  if ($script:Gui) { return }
  if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'The interface requires STA mode. Open ChatGPT-Switcher.cmd, or run PowerShell with -STA.'
  }
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
  $nativeCode = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
namespace CGS {
  public static class Desktop {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void EnableDpi() {
      try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch {}
      try { SetProcessDpiAwareness(2); } catch {}
    }
    public static void Chrome(Window w) {
      try { var h = new WindowInteropHelper(w).Handle; int dark=1, corner=2;
        DwmSetWindowAttribute(h,20,ref dark,4); DwmSetWindowAttribute(h,33,ref corner,4);
        int caption=0x000D0D0D, text=0x00E6E6E6, border=0x00272727;
        DwmSetWindowAttribute(h,35,ref caption,4); DwmSetWindowAttribute(h,36,ref text,4); DwmSetWindowAttribute(h,34,ref border,4);
      } catch {}
    }
  }
  public static class Motion {
    // Test override is never persisted and is not exposed as an application setting.
    public static bool? ReducedMotionOverride;
    public static bool Enabled { get { return !(ReducedMotionOverride ?? !SystemParameters.ClientAreaAnimation); } }
    static readonly List<WeakReference> resetters = new List<WeakReference>();
    static Motion() {
      SystemParameters.StaticPropertyChanged += PreferenceChanged;
      EventManager.RegisterClassHandler(typeof(System.Windows.Controls.Primitives.Thumb),
        FrameworkElement.LoadedEvent, new RoutedEventHandler(ConfigureScrollThumb));
    }
    static void ConfigureScrollThumb(object sender, RoutedEventArgs e) {
      var thumb = sender as System.Windows.Controls.Primitives.Thumb;
      if(thumb == null || thumb.Name != "SwitcherScrollThumb") return;
      var brush = new SolidColorBrush(ColorOf("#C7C7C7"));
      thumb.Background = brush;
      Func<Color> target = delegate {
        return ColorOf(thumb.IsDragging ? "#FFFFFF" : thumb.IsMouseOver ? "#E6E6E6" : "#C7C7C7");
      };
      Action update = delegate { ColorTo(brush,target()); };
      System.Windows.Input.MouseEventHandler hover = delegate { update(); };
      System.Windows.Controls.Primitives.DragStartedEventHandler start = delegate { update(); };
      System.Windows.Controls.Primitives.DragCompletedEventHandler finish = delegate { update(); };
      thumb.MouseEnter += hover;
      thumb.MouseLeave += hover;
      thumb.DragStarted += start; thumb.DragCompleted += finish;
      Watch(thumb,delegate { if(!Enabled) update(); });
      RoutedEventHandler unload = null;
      unload = delegate {
        thumb.MouseEnter -= hover;
        thumb.MouseLeave -= hover;
        thumb.DragStarted -= start; thumb.DragCompleted -= finish;
        thumb.Unloaded -= unload;
      };
      thumb.Unloaded += unload;
      update();
    }
    public static void RefreshPreferences() { PreferenceChanged(null,new PropertyChangedEventArgs("ClientAreaAnimation")); }
    static void PreferenceChanged(object s, PropertyChangedEventArgs e) {
      if(e.PropertyName != "ClientAreaAnimation" && e.PropertyName != "MenuAnimation") return;
      foreach(var r in resetters.ToArray()) {
        var a = r.Target as Action; if(a != null) a(); else resetters.Remove(r);
      }
    }
    static void Watch(FrameworkElement e, Action reset) {
      var r = new WeakReference(reset); resetters.Add(r);
      // Keep reset alive only for the lifetime of this visual.
      RoutedEventHandler gone = null;
      gone = delegate { StopVisual(e); resetters.Remove(r); e.Unloaded -= gone; GC.KeepAlive(reset); };
      e.Unloaded += gone;
    }
    static void StopTransform(Transform t) {
      if(t==null || t.IsFrozen) return;
      var g=t as TransformGroup; if(g!=null) { foreach(var child in g.Children) StopTransform(child); return; }
      var move=t as TranslateTransform; if(move!=null) { move.BeginAnimation(TranslateTransform.XProperty,null); move.BeginAnimation(TranslateTransform.YProperty,null); move.X=move.Y=0; }
      var scale=t as ScaleTransform; if(scale!=null) { scale.BeginAnimation(ScaleTransform.ScaleXProperty,null); scale.BeginAnimation(ScaleTransform.ScaleYProperty,null); scale.ScaleX=scale.ScaleY=1; }
      var rotate=t as RotateTransform; if(rotate!=null) { rotate.BeginAnimation(RotateTransform.AngleProperty,null); rotate.Angle=0; }
    }
    static void StopVisual(FrameworkElement e) {
      e.BeginAnimation(UIElement.OpacityProperty,null); e.Opacity=1; StopTransform(e.RenderTransform);
      var control=e as Control; var border=e as Border; var text=e as TextBlock;
      Brush[] brushes=control!=null ? new[]{control.Background,control.BorderBrush,control.Foreground} :
        border!=null ? new[]{border.Background,border.BorderBrush} : text!=null ? new[]{text.Foreground} : new Brush[0];
      foreach(var brush in brushes) { var solid=brush as SolidColorBrush; if(solid!=null && !solid.IsFrozen) solid.BeginAnimation(SolidColorBrush.ColorProperty,null); }
    }
    static DoubleAnimation Number(double from, double to, int ms) {
      return new DoubleAnimation(from,to,TimeSpan.FromMilliseconds(Enabled ? ms : 0)) {
        EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior=FillBehavior.Stop
      };
    }
    static void Animate(DependencyObject target, DependencyProperty prop, double from, double to, int ms, Storyboard sb) {
      var a=Number(from,to,ms); Storyboard.SetTarget(a,target); Storyboard.SetTargetProperty(a,new PropertyPath(prop)); sb.Children.Add(a);
    }
    static readonly DependencyProperty EntranceStoryboardProperty = DependencyProperty.RegisterAttached("EntranceStoryboard",typeof(Storyboard),typeof(Motion),new PropertyMetadata(null));
    public static void Entrance(FrameworkElement e, int ms, double slide, int delay, bool scale) {
      var previous=e.GetValue(EntranceStoryboardProperty) as Storyboard;
      if(previous!=null) { previous.Remove(e); e.ClearValue(EntranceStoryboardProperty); }
      e.Opacity=1;
      if(!Enabled) return;
      var transforms=new TransformGroup(); var translate=new TranslateTransform(0,0); var zoom=new ScaleTransform(1,1);
      transforms.Children.Add(translate); transforms.Children.Add(zoom); e.RenderTransform=transforms; e.RenderTransformOrigin=new Point(.5,.5);
      var sb=new Storyboard(); sb.BeginTime=TimeSpan.FromMilliseconds(delay);
      e.Opacity=0; translate.Y=slide;
      sb.Completed += delegate { if(e.GetValue(EntranceStoryboardProperty)!=sb) return; e.Opacity=1; translate.Y=0; zoom.ScaleX=zoom.ScaleY=1; sb.Remove(e); e.ClearValue(EntranceStoryboardProperty); };
      Animate(e,UIElement.OpacityProperty,0,1,ms,sb);
      Animate(translate,TranslateTransform.YProperty,slide,0,ms,sb);
      if(scale) { Animate(zoom,ScaleTransform.ScaleXProperty,.98,1,ms,sb); Animate(zoom,ScaleTransform.ScaleYProperty,.98,1,ms,sb); }
      Action reset=delegate { if(!Enabled && e.GetValue(EntranceStoryboardProperty)==sb) { sb.Remove(e); e.Opacity=1; translate.Y=0; zoom.ScaleX=zoom.ScaleY=1; e.ClearValue(EntranceStoryboardProperty); } };
      e.SetValue(EntranceStoryboardProperty,sb); Watch(e,reset); sb.Begin(e,true);
    }
    public static void Window(Window w, bool dialog) {
      bool closing=false, ready=false; Storyboard exit=null;
      w.SourceInitialized += delegate { Desktop.Chrome(w); };
      w.Loaded += delegate { var e=w.Content as FrameworkElement; if(e!=null) Entrance(e,dialog?180:220,dialog?0:8,0,dialog); };
      w.Closing += delegate(object s,CancelEventArgs e) {
        if(e.Cancel || ready) return;
        if(!Enabled) return;
        e.Cancel=true; if(closing) return; closing=true; w.IsEnabled=false;
        exit=new Storyboard(); Animate(w,UIElement.OpacityProperty,w.Opacity,0,dialog?180:180,exit);
        if(dialog) { var content=w.Content as FrameworkElement; if(content!=null) {
          var t=new ScaleTransform(1,1); content.RenderTransform=t; content.RenderTransformOrigin=new Point(.5,.5);
          Animate(t,ScaleTransform.ScaleXProperty,1,.98,180,exit); Animate(t,ScaleTransform.ScaleYProperty,1,.98,180,exit);
        } }
        exit.Completed += delegate { ready=true; w.Close(); }; exit.Begin(w,true);
      };
      Action reset=delegate { if(!Enabled && closing) { if(exit!=null) exit.Remove(w); ready=true; w.Close(); } };
      Watch(w,reset);
    }
    static Color ColorOf(string value) { return (Color)ColorConverter.ConvertFromString(value); }
    static void ColorTo(SolidColorBrush b, Color target) {
      var from=b.Color; b.BeginAnimation(SolidColorBrush.ColorProperty,null); b.Color=target;
      if(from==target) return;
      if(Enabled) b.BeginAnimation(SolidColorBrush.ColorProperty,new ColorAnimation(from,target,TimeSpan.FromMilliseconds(160)) { FillBehavior=FillBehavior.Stop });
    }
    public static readonly DependencyProperty SelectedProperty = DependencyProperty.RegisterAttached("Selected",typeof(bool),typeof(Motion),new PropertyMetadata(false));
    public static bool GetSelected(DependencyObject e) { return (bool)e.GetValue(SelectedProperty); }
    public static void SetSelected(DependencyObject e, bool value) { e.SetValue(SelectedProperty,value); }
    public static void Button(Button b, bool primary) { ConfigureButton(b,primary?1:0); }
    public static void Navigation(Button b) { ConfigureButton(b,2); }
    public static void Quiet(Button b) { ConfigureButton(b,3); }
    static void ConfigureButton(Button b, int kind) {
      var surface=new SolidColorBrush(ColorOf(kind==1?"#E6E6E6":kind==2?"#0A0A0A":kind==3?"#00000000":"#202020"));
      var border=new SolidColorBrush(ColorOf(kind==1?"#E6E6E6":kind==2?"#0A0A0A":kind==3?"#00000000":"#343434"));
      var ink=new SolidColorBrush(ColorOf(kind==1?"#151515":kind==2?"#939393":"#D4D4D4"));
      b.Background=surface; b.BorderBrush=border; b.Foreground=ink;
      var scale=new ScaleTransform(1,1); b.RenderTransform=scale; b.RenderTransformOrigin=new Point(.5,.5);
      bool hovering=b.IsMouseOver;
      Action state=delegate {
        bool selected=GetSelected(b), hover=hovering;
        string fill=kind==1?(hover?"#FAFAFA":"#E6E6E6"):
          kind==2?(selected?"#1C1C1C":hover?"#151515":"#0A0A0A"):
          kind==3?(hover?"#252525":"#00000000"):(hover?"#2B2B2B":"#202020");
        string edge=kind==1?fill:kind==2?fill:kind==3?fill:(hover?"#4A4A4A":"#343434");
        ColorTo(surface,ColorOf(fill));
        ColorTo(border,ColorOf(b.IsKeyboardFocused?"#858585":edge));
        ColorTo(ink,ColorOf(kind==1?"#111111":(selected||hover?"#F0F0F0":kind==2?"#939393":"#D4D4D4")));
        double target=b.IsPressed?.98:1;
        foreach(var prop in new[]{ScaleTransform.ScaleXProperty,ScaleTransform.ScaleYProperty}) {
          double from=(double)scale.GetValue(prop); scale.BeginAnimation(prop,null); scale.SetValue(prop,target);
          if(Enabled && Math.Abs(from-target)>.0001) scale.BeginAnimation(prop,Number(from,target,150));
        }
      };
      b.MouseEnter+=delegate{hovering=true;state();}; b.MouseLeave+=delegate{hovering=false;state();};
      b.GotKeyboardFocus+=delegate{state();}; b.LostKeyboardFocus+=delegate{state();};
      var pressed=DependencyPropertyDescriptor.FromProperty(System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty,typeof(System.Windows.Controls.Button));
      var selection=DependencyPropertyDescriptor.FromProperty(SelectedProperty,typeof(System.Windows.Controls.Button));
      EventHandler changed=delegate{state();};
      // Pages are hidden, not rebuilt. Reattach after a popup unload/reload too.
      bool listening=false;
      Action listen=delegate { if(listening) return; listening=true; pressed.AddValueChanged(b,changed); selection.AddValueChanged(b,changed); };
      b.Loaded+=delegate { hovering=b.IsMouseOver; listen(); state(); };
      b.Unloaded+=delegate { if(listening) { pressed.RemoveValueChanged(b,changed); selection.RemoveValueChanged(b,changed); listening=false; } };
      listen(); Watch(b,state);
    }
    public static void Card(Border b) {
      var surface=new SolidColorBrush(ColorOf("#171717")); var edge=new SolidColorBrush(ColorOf("#272727")); b.Background=surface; b.BorderBrush=edge; bool hovering=b.IsMouseOver;
      Action state=delegate { ColorTo(surface,ColorOf(hovering?"#1D1D1D":"#171717")); ColorTo(edge,ColorOf(hovering?"#393939":"#272727")); };
      b.MouseEnter+=delegate{hovering=true;state();}; b.MouseLeave+=delegate{hovering=false;state();}; Watch(b,state);
    }
    public static void Status(FrameworkElement badge, SolidColorBrush brush, bool running) {
      ColorTo(brush,ColorOf(running?"#59B99A":"#909090"));
      if(Enabled) { var sb=new Storyboard(); Animate(badge,UIElement.OpacityProperty,.45,1,160,sb);
        Action reset=delegate { if(!Enabled) { sb.Remove(badge); brush.BeginAnimation(SolidColorBrush.ColorProperty,null); badge.Opacity=1; } }; Watch(badge,reset); sb.Begin(badge,true); }
    }
    public static void Busy(FrameworkElement e, bool start) {
      var rotate=e.RenderTransform as RotateTransform;
      if(rotate==null) { rotate=new RotateTransform(0); e.RenderTransform=rotate; e.RenderTransformOrigin=new Point(.5,.5); }
      rotate.BeginAnimation(RotateTransform.AngleProperty,null);
      if(start && Enabled) rotate.BeginAnimation(RotateTransform.AngleProperty,new DoubleAnimation(0,360,TimeSpan.FromMilliseconds(800)) { RepeatBehavior=RepeatBehavior.Forever });
      Action reset=delegate { if(!Enabled) rotate.BeginAnimation(RotateTransform.AngleProperty,null); };
      if(start) Watch(e,reset);
    }
    public static void Menu(ContextMenu menu) {
      menu.CustomPopupPlacementCallback = delegate(Size popup, Size target, Point offset) {
        double x = (target.Width - popup.Width) / 2 + offset.X;
        return new[] {
          new System.Windows.Controls.Primitives.CustomPopupPlacement(new Point(x, target.Height + offset.Y), System.Windows.Controls.Primitives.PopupPrimaryAxis.Horizontal),
          new System.Windows.Controls.Primitives.CustomPopupPlacement(new Point(x, -popup.Height - offset.Y), System.Windows.Controls.Primitives.PopupPrimaryAxis.Horizontal)
        };
      };
      menu.Opened+=delegate { if(SystemParameters.MenuAnimation) Entrance(menu,160,4,0,false); };
    }
  }
  public sealed class TrayColors : System.Windows.Forms.ProfessionalColorTable {
    static System.Drawing.Color C(int r,int g,int b) { return System.Drawing.Color.FromArgb(r,g,b); }
    public override System.Drawing.Color ToolStripDropDownBackground { get { return C(23,23,23); } }
    public override System.Drawing.Color ImageMarginGradientBegin { get { return C(23,23,23); } }
    public override System.Drawing.Color ImageMarginGradientMiddle { get { return C(23,23,23); } }
    public override System.Drawing.Color ImageMarginGradientEnd { get { return C(23,23,23); } }
    public override System.Drawing.Color MenuItemSelected { get { return C(39,39,39); } }
    public override System.Drawing.Color MenuItemBorder { get { return C(64,64,64); } }
    public override System.Drawing.Color MenuBorder { get { return C(45,45,45); } }
    public override System.Drawing.Color SeparatorDark { get { return C(45,45,45); } }
    public override System.Drawing.Color SeparatorLight { get { return C(45,45,45); } }
  }
}

'@
  if (-not ('CGS.Motion' -as [type])) {
    $refs = @([System.Windows.Window].Assembly.Location, [System.Windows.Media.Brush].Assembly.Location,
      [System.Windows.DependencyObject].Assembly.Location, [System.Windows.Forms.Form].Assembly.Location,
      [System.Drawing.Bitmap].Assembly.Location, [System.ComponentModel.Component].Assembly.Location)
    # PowerShell 7's compiler needs the framework reference pack as well.
    if ($PSVersionTable.PSEdition -eq 'Core') { $refs += @('System.Runtime','System.Collections','System.ComponentModel','System.ComponentModel.Primitives','System.ComponentModel.TypeConverter','System.ObjectModel','System.Xaml','System.Drawing.Primitives') }
    else { $refs += @('System.Xaml','System.Core') }
    Add-Type -TypeDefinition $nativeCode -ReferencedAssemblies ($refs | Select-Object -Unique)
  }
  [CGS.Desktop]::EnableDpi()
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $script:Gui = $true
  Set-ProcessAppId
}

function Read-UiXaml {
  param([string]$Xaml)
  $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
  try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function New-UiResources {
  Read-UiXaml @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style TargetType="TextBlock">
    <Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style TargetType="Button">
    <Setter Property="Padding" Value="12,8"/><Setter Property="MinHeight" Value="40"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="FocusVisualStyle"><Setter.Value><Style><Setter Property="Control.Template"><Setter.Value>
      <ControlTemplate><Border Margin="-3" BorderBrush="#AAAAAA" BorderThickness="1" CornerRadius="11"/></ControlTemplate>
    </Setter.Value></Setter></Style></Setter.Value></Setter>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="Surface" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="True"/>
      </Border>
      <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.48"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="Background" Value="#0D0D0D"/><Setter Property="Foreground" Value="#E6E6E6"/>
    <Setter Property="CaretBrush" Value="#E3E3E3"/><Setter Property="SelectionBrush" Value="#444444"/>
    <Setter Property="Padding" Value="12,10"/><Setter Property="BorderBrush" Value="#777777"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
      <Border x:Name="Edge" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
        <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
      </Border>
      <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Edge" Property="BorderBrush" Value="#A5A5A5"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="RadioButton">
    <Setter Property="Foreground" Value="#E6E6E6"/><Setter Property="Margin" Value="0,8,0,0"/><Setter Property="FontSize" Value="14"/>
    <Setter Property="Cursor" Value="Hand"/><Setter Property="Padding" Value="8"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Border x:Name="Choice" CornerRadius="7" Padding="{TemplateBinding Padding}" Background="#171717" BorderThickness="1" BorderBrush="#303030">
        <StackPanel Orientation="Horizontal"><Grid Width="17" Height="17" Margin="0,0,10,0">
          <Ellipse Stroke="#888888" StrokeThickness="1.5"/><Ellipse x:Name="Dot" Width="9" Height="9" Fill="#E3E3E3" Visibility="Hidden"/>
        </Grid><ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/></StackPanel>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Dot" Property="Visibility" Value="Visible"/><Setter TargetName="Choice" Property="BorderBrush" Value="#787878"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Choice" Property="Background" Value="#202020"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Choice" Property="BorderBrush" Value="#59B99A"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="#202020"/><Setter Property="Foreground" Value="#D8D8D8"/>
    <Setter Property="BorderBrush" Value="#3A3A3A"/><Setter Property="Padding" Value="10,7"/>
    <Setter Property="MaxWidth" Value="360"/><Setter Property="FontSize" Value="12"/>
    <Setter Property="ContentTemplate"><Setter.Value><DataTemplate>
      <TextBlock Text="{Binding}" TextWrapping="Wrap" MaxWidth="340"/>
    </DataTemplate></Setter.Value></Setter>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
      <Border CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
        <ContentPresenter Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}"/>
      </Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ContextMenu">
    <Setter Property="Background" Value="#171717"/><Setter Property="Foreground" Value="#E6E6E6"/>
    <Setter Property="BorderBrush" Value="#303030"/><Setter Property="Padding" Value="6"/>
    <Setter Property="HasDropShadow" Value="True"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
        <ScrollViewer CanContentScroll="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Cycle"/>
        </ScrollViewer>
      </Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="MenuItem">
    <Setter Property="Padding" Value="12,10"/><Setter Property="MinHeight" Value="40"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
      <Border x:Name="MenuSurface" CornerRadius="5" Background="Transparent" Padding="{TemplateBinding Padding}">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <ContentPresenter ContentSource="Icon" HorizontalAlignment="Left" VerticalAlignment="Center"/><ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center"/>
        </Grid>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="MenuSurface" Property="Background" Value="#272727"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="MenuSurface" Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="Separator"><Setter Property="Template"><Setter.Value><ControlTemplate><Border Height="1" Margin="6,5" Background="#333333"/></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="12"/><Setter Property="Background" Value="Transparent"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
      <Track x:Name="PART_Track" IsDirectionReversed="True"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
        <Track.Thumb><Thumb x:Name="SwitcherScrollThumb" Background="#C7C7C7"><Thumb.Template><ControlTemplate TargetType="Thumb"><Grid Background="Transparent"><Border Width="1" HorizontalAlignment="Center" CornerRadius="0.5" Margin="0,2" Background="{TemplateBinding Background}"/></Grid></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
        <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
      </Track>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
</ResourceDictionary>
'@
}

function New-UiIcon {
  param([string]$Name, [string]$Color = '#999999', [int]$Size = 16)
  $paths = @{
    switch='M4,7 L20,7 M16,3 L20,7 L16,11 M20,17 L4,17 M8,13 L4,17 L8,21'
    plus='M12,5 L12,19 M5,12 L19,12'; arrow='M5,12 L19,12 M12,5 L19,12 L12,19'
    settings='M9,3 L15,3 L16,6 L19,7 L21,10 L19,12 L21,14 L19,17 L16,18 L15,21 L9,21 L8,18 L5,17 L3,14 L5,12 L3,10 L5,7 L8,6 Z M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12'
    more='M5,11 A1,1 0 1 1 5,13 A1,1 0 1 1 5,11 M12,11 A1,1 0 1 1 12,13 A1,1 0 1 1 12,11 M19,11 A1,1 0 1 1 19,13 A1,1 0 1 1 19,11'
    users='M16,21 L16,19 Q16,15 12,15 L6,15 Q2,15 2,19 L2,21 M13,7 A4,4 0 1 1 5,7 A4,4 0 1 1 13,7 M17,3 Q23,4 20,10 M22,21 L22,19 Q22,16 19,15'
    shield='M12,3 L20,6 L20,12 Q20,18 12,22 Q4,18 4,12 L4,6 Z M8,12 L11,15 L16,9'
    shared='M9,8 L15,5 M9,16 L15,19 M9,12 A3,3 0 1 1 3,12 A3,3 0 1 1 9,12 M21,4 A3,3 0 1 1 15,4 A3,3 0 1 1 21,4 M21,20 A3,3 0 1 1 15,20 A3,3 0 1 1 21,20'
    folder='M3,7 L3,20 L21,20 L21,7 L12,7 L10,4 L3,4 Z'
    edit='M14,5 L19,10 M4,20 L9,19 L21,7 L17,3 L5,15 Z'
    trash='M3,6 L21,6 M9,6 L9,3 L15,3 L15,6 M6,6 L7,21 L17,21 L18,6 M10,10 L10,17 M14,10 L14,17'
    save='M4,3 L18,3 L21,6 L21,21 L3,21 L3,3 Z M7,3 L7,9 L17,9 L17,3 M7,21 L7,14 L17,14 L17,21'
    link='M10,13 Q6,9 3,13 Q0,17 4,20 Q7,23 11,19 L14,16 M10,8 L13,5 Q17,1 20,5 Q24,9 20,12 L17,15 M8,16 L16,8'
    info='M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 M12,11 L12,17 M12,7 L12,8'
    tray='M3,14 L7,14 L9,17 L15,17 L17,14 L21,14 L21,21 L3,21 Z M12,2 L12,12 M8,8 L12,12 L16,8'
    power='M12,2 L12,12 M6,5 A9,9 0 1 0 18,5'
    refresh='M20,7 L20,3 M20,7 L16,7 M4,17 L4,21 M4,17 L8,17 M20,7 A9,9 0 0 0 4,9 M4,17 A9,9 0 0 0 20,15'
    spinner='M20,12 A8,8 0 1 1 12,4'
    check='M5,12 L10,17 L20,7'
  }
  $p = New-Object Windows.Shapes.Path
  $p.Data = [Windows.Media.Geometry]::Parse($paths[$Name])
  $p.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
  $p.StrokeThickness = 1.5; $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'; $p.StrokeLineJoin = 'Round'
  $p.Stretch = 'Uniform'; $p.Width = $Size; $p.Height = $Size
  return $p
}

function New-UiText {
  param([string]$Text, [double]$Size = 14, [string]$Color = '#E6E6E6')
  $t = New-Object Windows.Controls.TextBlock
  $t.Text=$Text; $t.FontSize=$Size; $t.LineHeight=$(if($Size -le 14){20}elseif($Size -le 20){24}else{28}); $t.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($Color)
  return $t
}

function New-UiButton {
  param([string]$Text, [string]$Icon, [switch]$Primary, [string]$Tip, [switch]$Navigation, [switch]$Quiet, [switch]$IconOnly)
  $b=New-Object Windows.Controls.Button
  $s=New-Object Windows.Controls.StackPanel; $s.Orientation='Horizontal'
  if ($Icon) {
    $i=New-UiIcon $Icon
    # Inherit the animated button foreground, including its icon.
    $binding=New-Object Windows.Data.Binding 'Foreground'; $binding.Source=$b
    [void]$i.SetBinding([Windows.Shapes.Shape]::StrokeProperty,$binding)
    $i.Margin=$(if($IconOnly){'0'}else{'0,0,7,0'}); [void]$s.Children.Add($i)
  }
  $l=New-Object Windows.Controls.TextBlock; $l.Text=$Text; $l.VerticalAlignment='Center'
  $binding=New-Object Windows.Data.Binding 'Foreground'; $binding.Source=$b
  [void]$l.SetBinding([Windows.Controls.TextBlock]::ForegroundProperty,$binding)
  if(-not $IconOnly) { [void]$s.Children.Add($l) }; $b.Content=$s
  [Windows.Automation.AutomationProperties]::SetName($b,$Text)
  if($Tip) { $b.ToolTip=$Tip }
  if($Navigation) { [CGS.Motion]::Navigation($b) } elseif($Quiet) { [CGS.Motion]::Quiet($b) } else { [CGS.Motion]::Button($b,[bool]$Primary) }
  return $b
}

function New-UiWindow {
  param([string]$Title, [double]$Width = 500, [switch]$Dialog)
  Ensure-Gui
  $w=New-Object Windows.Window
  $w.Title=$Title; $w.Width=$Width; $w.Background='#0D0D0D'; $w.Foreground='#E6E6E6'
  $iconPath=Get-AppIconPath -SwitcherOnly
  if($iconPath) { $w.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([uri]$iconPath) }
  $w.FontFamily='Segoe UI Variable, Segoe UI'; $w.FontSize=14; $w.Resources=New-UiResources
  $w.UseLayoutRounding=$true; $w.SnapsToDevicePixels=$true; $w.WindowStartupLocation='CenterScreen'
  $w.MinWidth=460; $w.SizeToContent='Height'; $w.MaxHeight=[Windows.SystemParameters]::WorkArea.Height
  if($Dialog) {
    $owner=Get-DialogOwner
    if($owner) { $w.Owner=$owner; $w.WindowStartupLocation='CenterOwner' }
    $w.ResizeMode='NoResize'; $w.ShowInTaskbar=$false
  }
  # Registered before the animated-close handler: a pending auth operation must finish.
  $w.add_Closing({ param($sender,$e)
    if($sender -eq $script:PickerForm -and $script:LaunchBusy) {
      $e.Cancel=$true; $script:CloseAfterLaunch=$true
      if($script:PickerHint) { $script:PickerHint.Text='Finishing the launch before closing…' }
    }
  })
  [CGS.Motion]::Window($w,[bool]$Dialog)
  return $w
}

function Get-DialogOwner {
  if($script:DialogWindow -and $script:DialogWindow.IsVisible) { return $script:DialogWindow }
  if($script:PickerForm -and $script:PickerForm.IsVisible) { return $script:PickerForm }
  return $null
}

function Show-UiDialog {
  param([string]$Title, [string]$Prompt, [string]$Kind='Message', [string]$Default='', [string]$Accept='OK')
  $isMessage=$Kind -eq 'Message'
  $width=if($isMessage){360}else{420}
  $workArea=[Windows.SystemParameters]::WorkArea
  $width=[Math]::Min($width,[Math]::Max(1,$workArea.Width-24))
  $w=New-UiWindow $Title $width -Dialog
  $w.MinWidth=0; $w.MaxHeight=[Math]::Max(1,$workArea.Height-24)
  $body=New-Object Windows.Controls.StackPanel; $body.Margin='20,16,20,18'
  if(-not $isMessage -or $Title -ne 'ChatGPT Switcher') {
    $head=New-UiText $Title 18; $head.FontWeight='SemiBold'; $head.Margin='0,0,0,8'
    if($isMessage) { $head.TextAlignment='Center' }
    [void]$body.Children.Add($head)
  }
  $text=New-UiText $Prompt 14 '#B5B5B5'
  if($isMessage) { $text.TextAlignment='Center' }
  else { $text.Margin='0,0,0,12' }
  [void]$body.Children.Add($text)
  $tb=$null; $isolated=$null; $shared=$null
  if($Kind -in @('Input','Add')) {
    $nameLabel=New-UiText 'Account name' 12 '#999999'; $nameLabel.Margin='0,0,0,8'; [void]$body.Children.Add($nameLabel)
    $tb=New-Object Windows.Controls.TextBox; $tb.Text=$Default; $tb.Margin='0,0,0,12'; $tb.FontSize=16; $tb.MaxLength=120
    [Windows.Automation.AutomationProperties]::SetName($tb,'Account name'); [void]$body.Children.Add($tb)
  }
  if($Kind -eq 'Add') {
    $isolated=New-Object Windows.Controls.RadioButton; $isolated.Content='Isolated'; $isolated.MinHeight=40; $isolated.IsChecked=$true; $isolated.GroupName='Mode'
    [void]$body.Children.Add($isolated)
    $t=New-UiText 'Separate login, projects, and chats. Open multiple accounts at once.' 12 '#999999'; $t.Margin='20,4,0,8'; [void]$body.Children.Add($t)
    $shared=New-Object Windows.Controls.RadioButton; $shared.Content='Shared projects'; $shared.MinHeight=40; $shared.GroupName='Mode'; [void]$body.Children.Add($shared)
    $t=New-UiText 'Share local projects, chats, and settings. Open one shared account at a time. Save its login after signing in.' 12 '#999999'; $t.Margin='20,4,0,4'; [void]$body.Children.Add($t)
  }
  $validation=$null
  if($tb) {
    $validation=New-UiText '' 12 '#DCA0A0'; $validation.MinHeight=16
    [void]$body.Children.Add($validation)
    $tb.Tag=$validation; $tb.add_TextChanged({ param($sender,$e) $sender.Tag.Text='' })
  }
  $buttons=New-Object Windows.Controls.StackPanel; $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment=$(if($isMessage){'Center'}else{'Right'}); $buttons.Margin='0,12,0,0'
  if($Kind -ne 'Message') {
    $cancel=New-UiButton 'Cancel'; $cancel.Margin='0,0,8,0'; $cancel.IsCancel=$true
    $cancel.add_Click({ param($sender,$e) [Windows.Window]::GetWindow($sender).Close() }); [void]$buttons.Children.Add($cancel)
  }
  $ok=New-UiButton $Accept -Primary; $ok.IsDefault=$true; $ok.MinWidth=76
  $ok.Tag=@{ Window=$w; Input=$tb; Shared=$shared; Validation=$validation; Kind=$Kind }
  $ok.add_Click({ param($sender,$e)
    $d=$sender.Tag
    if($d.Input -and [string]::IsNullOrWhiteSpace($d.Input.Text)) { $d.Validation.Text='Enter an account name.'; [void]$d.Input.Focus(); return }
    $d.Window.Tag=[pscustomobject]@{ Accepted=$true; Text=$(if($d.Input){$d.Input.Text.Trim()}else{''}); Shared=($d.Shared -and $d.Shared.IsChecked) }
    $d.Window.Close()
  })
  [void]$buttons.Children.Add($ok); [void]$body.Children.Add($buttons)
  $dialogScroll=New-Object Windows.Controls.ScrollViewer; $dialogScroll.VerticalScrollBarVisibility='Auto'; $dialogScroll.HorizontalScrollBarVisibility='Disabled'; $dialogScroll.Content=$body; $w.Content=$dialogScroll
  if($tb) { $w.Tag=$null; $w.add_ContentRendered({ param($sender,$e)
    $box=Find-UiChild $sender.Content ([Windows.Controls.TextBox]); if($box) { [void]$box.Focus(); $box.SelectAll() }
  }) }
  $previous=$script:DialogWindow; $script:DialogWindow=$w
  if([CGS.Motion]::Enabled) { $w.Content.Opacity=0 }
  try { [void]$w.ShowDialog(); return $w.Tag } finally { $script:DialogWindow=$previous }
}

function Find-UiChild {
  param([Windows.DependencyObject]$Root, [type]$Type)
  if($Type.IsInstanceOfType($Root)) { return $Root }
  for($n=0;$n -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root);$n++) {
    $result=Find-UiChild ([Windows.Media.VisualTreeHelper]::GetChild($Root,$n)) $Type
    if($result) { return $result }
  }
  return $null
}

function Show-Message {
  param([string]$Text,[string]$Title='ChatGPT Switcher',[string]$Icon='Information')
  [void](Show-UiDialog -Title $Title -Prompt $Text)
}
function Ask-YesNo {
  param([string]$Text,[string]$Title='ChatGPT Switcher')
  $r=Show-UiDialog -Title $Title -Prompt $Text -Kind 'Confirm' -Accept 'Continue'
  return ($null -ne $r -and $r.Accepted)
}
function Show-InputDialog {
  param([string]$Prompt,[string]$Title='ChatGPT Switcher',[string]$Default='')
  $r=Show-UiDialog -Title $Title -Prompt $Prompt -Kind 'Input' -Default $Default -Accept 'Save'
  if($r -and $r.Accepted) { return $r.Text }; return $null
}

function Invoke-AddAccountFlow {
  if($script:LaunchBusy) { return $null }
  $r=Show-UiDialog -Title 'Add account' -Prompt 'Give your account a name and choose how it uses local projects.' -Kind 'Add' -Accept 'Add account'
  if(-not $r -or -not $r.Accepted) { return $null }
  try {
    $acc=Add-Account -Display $r.Text -Shared:$r.Shared
    if($script:PickerForm -and $script:PickerForm.IsVisible) { Update-PickerRows }
    if($r.Shared) {
      Show-Message ('Profile "{0}" was added. To set up shared switching: first save your original login from Main account options. Then sign into this account in the desktop app and choose Save current login from the options for this profile. Use Open to switch. Close any independent Codex CLI or IDE clients first.' -f $acc.display) 'Save the logins before switching'
    } elseif(Ask-YesNo 'Your account and desktop shortcut are ready. Open it now?' 'Account added') { Invoke-UiLaunch $acc.id }
    return $acc
  } catch { Show-Message $_.Exception.Message 'Could not add account' 'Error'; return $null }
}

function New-UiMenu {
  $m=New-Object Windows.Controls.ContextMenu
  $m.Resources=New-UiResources; $m.FontSize=14
  [CGS.Motion]::Menu($m)
  return $m
}
function Add-UiMenuItem {
  param($Menu,[string]$Text,[string]$Icon,[string]$Action,[string]$Id)
  $item=New-Object Windows.Controls.MenuItem; $item.Header=$Text
  if($Icon) { $item.Icon=New-UiIcon $Icon -Size 16 }
  $item.Tag=@{Action=$Action;Id=$Id}
  $item.add_Click({ param($sender,$e) Invoke-UiAction $sender.Tag.Action $sender.Tag.Id })
  [void]$Menu.Items.Add($item)
}

function Invoke-UiAction {
  param([string]$Action,[string]$Id)
  if($script:LaunchBusy) { return }
  try {
    switch($Action) {
      'shortcut' { New-AccountShortcut (Get-ManagedAccount $Id) | Out-Null; Show-Message 'The desktop shortcut is ready.' }
      'rename' {
        $acc=Get-ManagedAccount $Id
        $name=Show-InputDialog 'Choose a new display name. Its login and data folder stay the same.' 'Rename account' $acc.display
        if(-not [string]::IsNullOrWhiteSpace($name)) { Rename-Account $Id $name; Update-PickerRows }
      }
      'remove' {
        $acc=Find-Account $Id
        $r=Show-UiDialog 'Remove account?' ('Remove "{0}" from this PC? Its local login, projects, chats, and cache will be deleted. Your online account and cloud history will remain.' -f $acc.display) 'Confirm' -Accept 'Remove account'
        if($r -and $r.Accepted) { Remove-Account $Id; Update-PickerRows }
      }
      'save' {
        $acc=Get-ManagedAccount $Id
        $info=Get-AuthProfileInfo (Join-Path (Get-RealCodexHome) 'auth.json')
        $who=if($info -and $info.Email){'Current login file: '+$info.Email+"`n`n"}else{''}
        if(Ask-YesNo ($who+('Save the login currently used by the main app as "{0}"? Only continue if you have signed in to the intended account.' -f $acc.display)) 'Save current login') {
          Save-CurrentAuthToAccount $acc; Update-PickerRows; Show-Message ('The current login was saved for "{0}".' -f $acc.display)
        }
      }
      'setup' { New-PickerShortcuts | Out-Null; Show-Message 'Desktop and Start menu shortcuts are ready.' }
      'tray' {
        if($script:TrayIcon) { Show-Message 'ChatGPT Switcher is already running in the system tray.' }
        else { Start-Process -FilePath (Get-PowerShellExe) -WindowStyle Hidden -ArgumentList ('-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Tray' -f $script:ScriptPath) }
      }
      'startup' { Install-TrayAutoStart | Out-Null; Show-Message 'Tray mode will start when you sign in to Windows.' }
      'folder' { New-Item -ItemType Directory -Force -Path $script:Root | Out-Null; Start-Process explorer.exe ('"{0}"' -f $script:Root) }
      'diagnose' { Start-Process -FilePath (Get-PowerShellExe) -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -Diagnose' -f $script:ScriptPath) }
    }
  } catch { Show-Message $_.Exception.Message 'Action failed' 'Error' }
}

function New-UiPageHeader {
  param([string]$Title,[string]$Description)
  $header=New-Object Windows.Controls.StackPanel; $header.Margin='0,0,0,24'
  $heading=New-UiText $Title 24 '#E6E6E6'; $heading.FontWeight='Medium'; [void]$header.Children.Add($heading)
  if(-not [string]::IsNullOrWhiteSpace($Description)) {
    $sub=New-UiText $Description 14 '#A0A0A0'; $sub.Margin='0,8,0,0'; [void]$header.Children.Add($sub)
  }
  return $header
}

function Set-UiPage {
  param([ValidateSet('Accounts','Settings','About')][string]$Page,[switch]$Initial)
  if(-not $script:Pages -or ($script:CurrentPage -eq $Page -and -not $Initial)) { return }
  $moveFocus=($script:CurrentPage -and $script:Pages[$script:CurrentPage].IsKeyboardFocusWithin)
  foreach($key in @($script:Pages.Keys)) {
    $script:Pages[$key].Visibility=$(if($key -eq $Page){'Visible'}else{'Collapsed'})
    [CGS.Motion]::SetSelected($script:NavButtons[$key],($key -eq $Page))
  }
  $script:CurrentPage=$Page
  if(-not $Initial) { [CGS.Motion]::Entrance($script:Pages[$Page],180,4,0,$false) }
  if($Page -eq 'Accounts' -and -not $script:LaunchBusy -and -not $Initial) { Update-PickerStatus }
  if($moveFocus) {
    if($Page -eq 'Accounts' -and $script:LaunchButtons.Count -gt 0) { [void]$script:LaunchButtons[0].Focus() }
    elseif($Page -eq 'Settings' -and $script:SettingsActions.Count -gt 0) { [void]$script:SettingsActions[0].Focus() }
    else { [void]$script:NavButtons[$Page].Focus() }
  }
}

function New-UiSettingsGroup {
  param([string]$Label,[object[]]$Rows)
  $group=New-Object Windows.Controls.StackPanel; $group.Margin='0,0,0,24'
  $caption=New-UiText $Label 14 '#A0A0A0'; $caption.Margin='0,0,0,12'; [void]$group.Children.Add($caption)
  $surface=New-Object Windows.Controls.Border; $surface.Background='#171717'; $surface.BorderBrush='#272727'; $surface.BorderThickness=1; $surface.CornerRadius=10
  $items=New-Object Windows.Controls.StackPanel
  $index=0
  foreach($row in $Rows) {
    $wrap=New-Object Windows.Controls.Border; $wrap.Padding='16'
    $grid=New-Object Windows.Controls.Grid
    foreach($width in @('Auto','*','Auto')) { $c=New-Object Windows.Controls.ColumnDefinition; $c.Width=$width; [void]$grid.ColumnDefinitions.Add($c) }
    $icon=New-UiIcon $row.Icon '#A0A0A0' 16; $icon.Margin='0,2,12,0'; $icon.VerticalAlignment='Top'; [void]$grid.Children.Add($icon)
    $copy=New-Object Windows.Controls.StackPanel; $copy.Margin='0,0,12,0'; [Windows.Controls.Grid]::SetColumn($copy,1)
    $title=New-UiText $row.Title 14 '#E6E6E6'; $title.FontWeight='Medium'; [void]$copy.Children.Add($title)
    $description=New-UiText $row.Description 12 '#A0A0A0'; $description.Margin='0,4,0,0'; [void]$copy.Children.Add($description); [void]$grid.Children.Add($copy)
    $action=New-UiButton $row.Button -Tip $row.Description; $action.FontSize=12; $action.Padding='12,8'; $action.MinHeight=40; $action.MinWidth=72; $action.VerticalAlignment='Center'
    $action.Tag=@{Action=$row.Action;Id=''}; $action.add_Click({ param($sender,$e) Invoke-UiAction $sender.Tag.Action })
    [Windows.Automation.AutomationProperties]::SetName($action,($row.Title+' - '+$row.Button))
    [Windows.Controls.Grid]::SetColumn($action,2); [void]$grid.Children.Add($action); $script:SettingsActions+=@($action)
    $wrap.Child=$grid; [void]$items.Children.Add($wrap); $index++
  }
  $surface.Child=$items; [void]$group.Children.Add($surface)
  return $group
}

function New-UiSettingsPage {
  $scroll=New-Object Windows.Controls.ScrollViewer; $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'
  $body=New-Object Windows.Controls.StackPanel; $body.Margin='0,0,4,0'
  [void]$body.Children.Add((New-UiPageHeader 'Settings' ''))
  $script:SettingsActions=@()
  $windows=@(
    @{Title='App shortcuts';Description='Add the switcher to your Desktop and Start menu.';Button='Create';Icon='link';Action='setup'},
    @{Title='System tray';Description='Keep account switching a click away.';Button='Start';Icon='tray';Action='tray'},
    @{Title='Start at sign-in';Description='Open tray mode when you sign in to Windows.';Button='Enable';Icon='power';Action='startup'}
  )
  [void]$body.Children.Add((New-UiSettingsGroup 'Windows integration' $windows))
  $tools=@(
    @{Title='Account files';Description='Open the local account data folder.';Button='Open';Icon='folder';Action='folder'},
    @{Title='Diagnostics';Description='View app detection and launch information.';Button='View';Icon='info';Action='diagnose'}
  )
  [void]$body.Children.Add((New-UiSettingsGroup 'Tools' $tools))
  $note=New-UiText 'Motion follows the Animation effects preference in Windows.' 12 '#909090'; $note.Margin='0,0,0,4'; [void]$body.Children.Add($note)
  $scroll.Content=$body
  return $scroll
}

function New-UiAboutPage {
  $scroll=New-Object Windows.Controls.ScrollViewer; $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'
  $body=New-Object Windows.Controls.StackPanel; $body.Margin='0,0,4,0'
  [void]$body.Children.Add((New-UiPageHeader 'About' ''))
  $surface=New-Object Windows.Controls.Border; $surface.Background='#171717'; $surface.BorderBrush='#272727'; $surface.BorderThickness=1; $surface.CornerRadius=12; $surface.Padding=24
  $inside=New-Object Windows.Controls.StackPanel
  $mark=New-UiIcon 'switch' '#E5E5E5' 28; $mark.HorizontalAlignment='Left'; $mark.Margin='0,0,0,17'; [void]$inside.Children.Add($mark)
  $name=New-UiText 'ChatGPT Switcher' 20 '#ECECEC'; $name.FontWeight='SemiBold'; [void]$inside.Children.Add($name)
  $version=New-UiText ('Version '+$script:AppVersion) 12 '#909090'; $version.Margin='0,6,0,20'; [void]$inside.Children.Add($version)
  foreach($entry in @(
    @{Title='Main';Copy='Your original desktop app session.'},
    @{Title='Isolated';Copy='Separate logins, projects, and chats. Multiple accounts can run together.'},
    @{Title='Shared projects';Copy='Shared local projects and chats. Close the current shared app before switching.'}
  )) {
    $title=New-UiText $entry.Title 14 '#E6E6E6'; $title.FontWeight='Medium'; [void]$inside.Children.Add($title)
    $copy=New-UiText $entry.Copy 12 '#999999'; $copy.Margin='0,4,0,20'; [void]$inside.Children.Add($copy)
  }
  $surface.Child=$inside; [void]$body.Children.Add($surface)
  $note=New-UiText 'An independent utility. Not affiliated with OpenAI.' 12 '#909090'; $note.Margin='0,18,0,0'; [void]$body.Children.Add($note)
  $scroll.Content=$body
  return $scroll
}

function Show-Picker {
  Ensure-Gui
  if($script:PickerForm -and $script:PickerForm.IsVisible) { [void]$script:PickerForm.Activate(); return }
  Set-JumpList
  $w=New-UiWindow 'ChatGPT Switcher' 800
  $w.MinWidth=[Math]::Min(720,[Windows.SystemParameters]::WorkArea.Width)
  $w.Width=[Math]::Min(800,[Windows.SystemParameters]::WorkArea.Width)
  $accountCount=1+@((Get-Config).accounts).Count
  $desiredHeight=[Math]::Min(672,[Math]::Max(432,232+196*$accountCount))
  $w.Height=[Math]::Min($desiredHeight,[Windows.SystemParameters]::WorkArea.Height)
  $w.MinHeight=[Math]::Min(432,[Windows.SystemParameters]::WorkArea.Height); $w.SizeToContent='Manual'
  $root=New-Object Windows.Controls.Grid
  foreach($width in @('164','*')) { $column=New-Object Windows.Controls.ColumnDefinition; $column.Width=$width; [void]$root.ColumnDefinitions.Add($column) }
  $sidebar=New-Object Windows.Controls.Border; $sidebar.Background='#0A0A0A'; $sidebar.BorderBrush='#232323'; $sidebar.BorderThickness='0,0,1,0'
  $rail=New-Object Windows.Controls.Grid; $rail.Margin='16,24,16,20'
  foreach($height in @('Auto','Auto','*','Auto','Auto')) { $row=New-Object Windows.Controls.RowDefinition; $row.Height=$height; [void]$rail.RowDefinitions.Add($row) }
  $brand=New-Object Windows.Controls.Grid; $brand.Margin='4,0,0,32'
  $brand.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()); $brand.ColumnDefinitions[0].Width='Auto'
  $brand.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()); $brand.ColumnDefinitions[1].Width='*'
  $mark=New-UiIcon 'switch' '#E8E8E8' 23; $mark.Margin='0,0,12,0'; $mark.VerticalAlignment='Center'; [void]$brand.Children.Add($mark)
  $brandCopy=New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($brandCopy,1)
  $brandName=New-UiText 'ChatGPT' 14 '#E6E6E6'; $brandName.FontWeight='SemiBold'; [void]$brandCopy.Children.Add($brandName)
  $brandSub=New-UiText 'Switcher' 12 '#909090'; $brandSub.Margin='0,2,0,0'; [void]$brandCopy.Children.Add($brandSub); [void]$brand.Children.Add($brandCopy); [void]$rail.Children.Add($brand)
  $nav=New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetRow($nav,1)
  $caption=New-UiText 'Workspace' 12 '#909090'; $caption.Margin='8,0,0,8'; [void]$nav.Children.Add($caption)
  $script:NavButtons=@{}
  foreach($entry in @(@{Name='Accounts';Icon='users'},@{Name='Settings';Icon='settings'},@{Name='About';Icon='info'})) {
    $button=New-UiButton $entry.Name $entry.Icon -Navigation -Tip ('View '+$entry.Name.ToLowerInvariant())
    $button.Tag=$entry.Name; $button.HorizontalContentAlignment='Left'; $button.Padding='8,8'; $button.FontSize=14; $button.MinHeight=40; $button.Margin='0,0,0,4'
    $button.add_Click({ param($sender,$e) Set-UiPage $sender.Tag })
    $script:NavButtons[$entry.Name]=$button
  }
  [void]$nav.Children.Add($script:NavButtons['Accounts']); [void]$rail.Children.Add($nav)
  $system=New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetRow($system,3)
  $caption=New-UiText 'Application' 12 '#909090'; $caption.Margin='8,0,0,8'; [void]$system.Children.Add($caption)
  [void]$system.Children.Add($script:NavButtons['Settings']); [void]$system.Children.Add($script:NavButtons['About']); [void]$rail.Children.Add($system)
  $version=New-UiText ('v'+$script:AppVersion) 12 '#909090'; $version.Margin='8,20,0,0'
  [Windows.Controls.Grid]::SetRow($version,4); [void]$rail.Children.Add($version)
  $sidebar.Child=$rail; [void]$root.Children.Add($sidebar)
  $hostPanel=New-Object Windows.Controls.Grid; $hostPanel.Margin='24,24,24,24'; [Windows.Controls.Grid]::SetColumn($hostPanel,1); [void]$root.Children.Add($hostPanel)
  $accounts=New-Object Windows.Controls.Grid
  foreach($height in @('Auto','Auto','*','Auto')) { $row=New-Object Windows.Controls.RowDefinition; $row.Height=$height; [void]$accounts.RowDefinitions.Add($row) }
  $header=New-Object Windows.Controls.Grid; $header.Margin='0,0,0,20'
  $copy=New-UiPageHeader 'Accounts' ''; $copy.Margin=0; [void]$header.Children.Add($copy)
  $script:AddButton=New-UiButton 'Add account' 'plus' -Primary -Tip 'Create an isolated account or share local projects.'
  $script:AddButton.HorizontalAlignment='Right'; $script:AddButton.VerticalAlignment='Top'; $script:AddButton.Padding='12,8'; $script:AddButton.MinHeight=40; $script:AddButton.FontSize=14
  $script:AddButton.add_Click({ Invoke-AddAccountFlow | Out-Null }); [void]$header.Children.Add($script:AddButton); [void]$accounts.Children.Add($header)
  $section=New-Object Windows.Controls.Grid; $section.Margin='0,0,0,12'; [Windows.Controls.Grid]::SetRow($section,1)
  $script:AccountCount=New-UiText '' 12 '#909090'; [void]$section.Children.Add($script:AccountCount); [void]$accounts.Children.Add($section)
  $scroll=New-Object Windows.Controls.ScrollViewer; $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'; $scroll.CanContentScroll=$false
  [Windows.Controls.Grid]::SetRow($scroll,2)
  $script:PickerPanel=New-Object Windows.Controls.StackPanel; $script:PickerPanel.Margin='0,0,6,0'; $scroll.Content=$script:PickerPanel; [void]$accounts.Children.Add($scroll)
  $script:PickerHint=New-UiText 'Isolated accounts can run together. Shared projects open one at a time.' 12 '#909090'
  $script:PickerHint.Margin='0,16,0,0'; [Windows.Controls.Grid]::SetRow($script:PickerHint,3); [void]$accounts.Children.Add($script:PickerHint)
  $script:Pages=@{Accounts=$accounts;Settings=(New-UiSettingsPage);About=(New-UiAboutPage)}
  foreach($key in @('Accounts','Settings','About')) { [void]$hostPanel.Children.Add($script:Pages[$key]) }
  $script:SettingsButton=$script:NavButtons['Settings']; $script:CurrentPage=$null
  $w.Content=$root; $script:PickerForm=$w; $script:PickerScroll=$scroll; $script:CloseAfterLaunch=$false; $script:PickerReady=$false; $script:PickerCloseReason='window dismissed'
  $w.add_PreviewKeyDown({ param($sender,$e) if($e.Key -eq 'Escape' -and -not $script:DialogWindow) {
    if($script:CurrentPage -ne 'Accounts') { Set-UiPage 'Accounts' } else { $sender.Close() }; $e.Handled=$true
  } })
  $w.add_Loaded({
    $script:PickerReady=$true
    $script:PickerPanel.UpdateLayout(); $index=0
    foreach($card in $script:PickerPanel.Children) {
      $point=$card.TranslatePoint([Windows.Point]::new(0,0),$script:PickerScroll)
      if($point.Y -lt $script:PickerScroll.ViewportHeight) { [CGS.Motion]::Entrance($card,200,5,[Math]::Min($index*20,40),$false) }; $index++
    }
    if($script:LaunchButtons.Count -gt 0) { [void]$script:LaunchButtons[0].Focus() }
    Queue-VisibleUsageRefresh
    Queue-VisibleProfileRefresh
  })
  $w.add_Activated({ if($script:PickerReady -and -not $script:LaunchBusy -and $script:CurrentPage -eq 'Accounts' -and $script:PickerPanel.Children.Count -gt 0) { Update-PickerStatus } })
  $w.add_Closed({ $script:ProfileQueue=@(); Stop-ProfileRefresh; $script:UsageQueue=@(); Stop-UsageRefresh; Write-Log ('picker closed: '+$script:PickerCloseReason); $script:PickerForm=$null; $script:PickerPanel=$null; $script:StatusBadges=@{}; $script:LaunchButtons=@(); $script:OptionButtons=@()
    $script:PickerScroll=$null; $script:PickerHint=$null; $script:AccountCount=$null; $script:AddButton=$null; $script:SettingsButton=$null
    $script:Pages=$null; $script:NavButtons=$null; $script:SettingsActions=@(); $script:CurrentPage=$null; $script:PickerReady=$false })
  Update-PickerRows; Set-UiPage 'Accounts' -Initial
  if($script:LaunchBusy) { Set-UiBusy $true $script:LaunchingId }
  if([CGS.Motion]::Enabled) { $root.Opacity=0 }
  [void]$w.ShowDialog()
}

function Ensure-UsageClient {
  if('CGS.UsageRequest' -as [type]) { return }
  Add-Type -AssemblyName System.Net.Http
  $usageCode=@"
using System;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace CGS {
  public sealed class UsageReply {
    public int Status;
    public string Json;
    public byte[] Bytes;
  }
  public sealed class UsageRequest : IDisposable {
    readonly HttpClient client;
    readonly Uri endpoint;
    readonly bool image;
    readonly CancellationTokenSource cancellation = new CancellationTokenSource();
    public Task<UsageReply> Task { get; private set; }
    public UsageRequest(string token, string accountId) :
      this(token,accountId,new Uri("https://chatgpt.com/backend-api/wham/usage"),false) { }
    public UsageRequest(string token, string accountId, bool profile) :
      this(token,accountId,new Uri(profile ? "https://chatgpt.com/backend-api/me" : "https://chatgpt.com/backend-api/wham/usage"),false) { }
    public UsageRequest(string token, string accountId, Uri picture) :
      this(token,accountId,ValidatePicture(picture),true) { }
    public static bool SupportsPicture(Uri uri) {
      if(uri == null || !uri.IsAbsoluteUri || uri.Scheme != "https" || uri.Port != 443 ||
        !String.IsNullOrEmpty(uri.UserInfo) || uri.IsLoopback) return false;
      string host=uri.DnsSafeHost.ToLowerInvariant();
      return host == "chatgpt.com" || host == "images.openai.com" ||
        host.EndsWith(".oaistatic.com") || host.EndsWith(".oaiusercontent.com") ||
        host == "lh3.googleusercontent.com" || host == "lh4.googleusercontent.com" ||
        host == "lh5.googleusercontent.com" || host == "lh6.googleusercontent.com" ||
        host == "secure.gravatar.com" || host == "www.gravatar.com" || host == "cdn.auth0.com";
    }
    static Uri ValidatePicture(Uri uri) {
      if(!SupportsPicture(uri)) throw new ArgumentException("Unsupported profile image address.");
      return uri;
    }
    UsageRequest(string token, string accountId, Uri uri, bool isImage) {
      endpoint=uri; image=isImage;
      var handler = new HttpClientHandler { AllowAutoRedirect=false, UseCookies=false };
      client = new HttpClient(handler);
      client.Timeout = TimeSpan.FromSeconds(12);
      // Credentials are sent only to ChatGPT's own authenticated backend routes.
      if(uri.Host == "chatgpt.com" && uri.AbsolutePath.StartsWith("/backend-api/",StringComparison.Ordinal)) {
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer",token);
        client.DefaultRequestHeaders.Add("ChatGPT-Account-Id",accountId);
      }
      client.DefaultRequestHeaders.Add("User-Agent","ChatGPT-Switcher");
      client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue(isImage ? "image/*" : "application/json"));
      cancellation.CancelAfter(12000);
      Task = ReadAsync();
    }
    async Task<UsageReply> ReadAsync() {
      try {
        using(var message = new HttpRequestMessage(HttpMethod.Get,endpoint))
        using(var response = await client.SendAsync(message,HttpCompletionOption.ResponseHeadersRead,cancellation.Token).ConfigureAwait(false)) {
          if(!response.IsSuccessStatusCode) return new UsageReply { Status=(int)response.StatusCode };
          if(image && (response.Content.Headers.ContentType == null ||
            !response.Content.Headers.ContentType.MediaType.StartsWith("image/",StringComparison.OrdinalIgnoreCase))) return new UsageReply { Status=0 };
          using(var registration = cancellation.Token.Register(delegate { response.Dispose(); }))
          using(var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
          using(var bytes = new MemoryStream()) {
            var buffer = new byte[4096];
            int count;
            while((count = await stream.ReadAsync(buffer,0,buffer.Length,cancellation.Token).ConfigureAwait(false)) > 0) {
              if(bytes.Length+count > (image ? 12582912 : 1048576)) return new UsageReply { Status=0 };
              bytes.Write(buffer,0,count);
            }
            var content=bytes.ToArray();
            return new UsageReply { Status=(int)response.StatusCode, Json=image ? null : Encoding.UTF8.GetString(content), Bytes=image ? content : null };
          }
        }
      } catch { return new UsageReply { Status=0 }; }
    }
    public void Dispose() {
      cancellation.Cancel();
      client.Dispose();
      cancellation.Dispose();
    }
  }
}
"@
  if($PSVersionTable.PSEdition -eq 'Core') { Add-Type -TypeDefinition $usageCode }
  else { Add-Type -TypeDefinition $usageCode -ReferencedAssemblies 'System.Net.Http' }
}

function Get-UsageAuthPath {
  param([string]$Id)
  $account=Get-ManagedAccount $Id
  if(-not $account) { throw 'The account was not found.' }
  if($account.mode -ne 'shared') { return (Join-Path (Get-AccountPaths $Id).Codex 'auth.json') }
  $saved=Get-SharedAuthStore $account
  $currentPath=Join-Path (Get-RealCodexHome) 'auth.json'
  $current=Get-AuthProfileInfo $currentPath
  $profile=Get-AuthProfileInfo $saved
  if($profile -and $current -and $profile.Identity -ceq $current.Identity) { return $currentPath }
  if($Id -eq $script:MainId -and -not $profile -and -not (Get-ActiveShared)) { return $currentPath }
  return $saved
}

function Convert-UsagePayload {
  param([string]$Json,[string]$AccountId)
  $data=$Json | ConvertFrom-Json -ErrorAction Stop
  if($data.account_id -and $data.account_id -cne $AccountId) { throw 'Usage belongs to a different account.' }
  $windows=@($data.rate_limit.primary_window,$data.rate_limit.secondary_window)
  $result=@{}
  foreach($entry in @(@{Key='FiveHour';Seconds=18000},@{Key='Weekly';Seconds=604800})) {
    $window=$windows | Where-Object { $_ -and $_.limit_window_seconds -eq $entry.Seconds } | Select-Object -First 1
    if(-not $window -or $null -eq $window.used_percent) { $result[$entry.Key]=$null; continue }
    $used=0.0
    if(-not [double]::TryParse([string]$window.used_percent,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$used) -or
       [double]::IsNaN($used) -or [double]::IsInfinity($used) -or $used -lt 0 -or $used -gt 100) {
      throw 'The usage response contains an invalid percentage.'
    }
    $reset=$null
    if($window.reset_at) {
      try { $reset=[DateTimeOffset]::FromUnixTimeSeconds([long]$window.reset_at).LocalDateTime } catch {}
    }
    $result[$entry.Key]=[pscustomobject]@{Remaining=(100-$used);Reset=$reset}
  }
  return [pscustomobject]@{FiveHour=$result.FiveHour;Weekly=$result.Weekly;Updated=[DateTime]::Now}
}

function New-UsageMeter {
  param([string]$Label)
  $panel=New-Object Windows.Controls.StackPanel
  $text=New-UiText ($Label+'  —') 12 '#A0A0A0'
  $text.TextWrapping='NoWrap'; $text.TextTrimming='CharacterEllipsis'
  [void]$panel.Children.Add($text)
  $track=New-Object Windows.Controls.Border
  $track.Height=2; $track.Background='#303030'; $track.CornerRadius=1; $track.Margin='0,7,0,0'
  $fill=New-Object Windows.Controls.Border
  $fill.Background='#BDBDBD'; $fill.CornerRadius=1
  $grid=New-Object Windows.Controls.Grid
  $remaining=New-Object Windows.Controls.ColumnDefinition; $remaining.Width='0*'
  $used=New-Object Windows.Controls.ColumnDefinition; $used.Width='100*'
  [void]$grid.ColumnDefinitions.Add($remaining); [void]$grid.ColumnDefinitions.Add($used)
  [void]$grid.Children.Add($fill); $track.Child=$grid; [void]$panel.Children.Add($track)
  return @{Panel=$panel;Text=$text;Column=$remaining;OtherColumn=$used;Fill=$fill;Label=$Label}
}

function Set-ProfileAvatar {
  param([string]$Id)
  if(-not $script:StatusBadges -or -not $script:StatusBadges.ContainsKey($Id)) { return }
  $visual=$script:StatusBadges[$Id]
  $profile=Get-AuthProfileInfo (Get-UsageAuthPath $Id)
  $cached=$script:ProfileCache[$Id]
  if($cached -and $profile -and $cached.Identity -ceq $profile.Identity -and $cached.Image) {
    $image=New-Object Windows.Controls.Image
    $image.Source=$cached.Image; $image.Width=38; $image.Height=38; $image.Stretch='UniformToFill'
    $image.Clip=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,38,38),11,11)
    $visual.Avatar.Child=$image
    $visual.Avatar.ToolTip='ChatGPT profile picture'
    [Windows.Automation.AutomationProperties]::SetName($image,('Profile picture for '+$profile.Email))
  } else {
    $visual.Avatar.Child=$visual.Initial
    $visual.Avatar.ToolTip='Account initials'
  }
}

function Convert-ProfilePicture {
  param([byte[]]$Bytes)
  if(-not $Bytes -or $Bytes.Length -gt 12582912) { throw 'Unsupported profile image.' }
  $stream=[IO.MemoryStream]::new($Bytes,$false)
  try {
    $image=[Windows.Media.Imaging.BitmapImage]::new()
    $image.BeginInit(); $image.CacheOption='OnLoad'; $image.DecodePixelWidth=80
    $image.StreamSource=$stream; $image.EndInit(); $image.Freeze()
    return $image
  } finally { $stream.Dispose() }
}

function Stop-ProfileRefresh {
  if($script:ProfileTimer) { $script:ProfileTimer.Stop(); $script:ProfileTimer=$null }
  if($script:ProfileJob) { $script:ProfileJob.Request.Dispose(); $script:ProfileJob=$null }
}

function Invoke-NextProfileRefresh {
  if($script:ProfileJob -or $script:LaunchBusy -or -not $script:PickerForm -or -not $script:PickerForm.IsVisible) { return }
  if(@($script:ProfileQueue).Count -eq 0) { return }
  $id=$script:ProfileQueue[0]
  $script:ProfileQueue=@($script:ProfileQueue | Select-Object -Skip 1)
  Invoke-ProfileRefresh $id
}

function Queue-VisibleProfileRefresh {
  $script:ProfileQueue=@()
  foreach($id in @($script:UsageCards.Keys)) {
    $card=$script:UsageCards[$id].Surface
    $point=$card.TranslatePoint([Windows.Point]::new(0,0),$script:PickerScroll)
    if($point.Y -ge $script:PickerScroll.ViewportHeight -or $point.Y+$card.ActualHeight -le 0) { continue }
    $profile=Get-AuthProfileInfo (Get-UsageAuthPath $id)
    if(-not $profile -or $profile.Kind -ne 'chatgpt') { continue }
    $cached=$script:ProfileCache[$id]
    if($cached -and $cached.Identity -ceq $profile.Identity -and ([DateTime]::Now-$cached.Checked).TotalMinutes -lt 30) { continue }
    $script:ProfileQueue+=@($id)
  }
  Invoke-NextProfileRefresh
}

function New-ProfileRequest {
  param([string]$AccessToken,[string]$AccountId,[uri]$Picture)
  if($Picture) { return [CGS.UsageRequest]::new($AccessToken,$AccountId,$Picture) }
  return [CGS.UsageRequest]::new($AccessToken,$AccountId,$true)
}

function Invoke-ProfileRefresh {
  param([string]$Id)
  if($script:ProfileJob -or $script:LaunchBusy) { return }
  try {
    Ensure-UsageClient
    $path=Get-UsageAuthPath $Id
    $profile=Get-AuthProfileInfo $path
    if(-not $profile -or $profile.Kind -ne 'chatgpt') { return }
    $auth=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    $request=New-ProfileRequest ([string]$auth.tokens.access_token) ([string]$auth.tokens.account_id)
    $script:ProfileJob=@{Id=$Id;Identity=$profile.Identity;Email=$profile.Email;Request=$request;Stage='Profile'}
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $timer.add_Tick({
      if(-not $script:ProfileJob -or -not $script:ProfileJob.Request.Task.IsCompleted) { return }
      $job=$script:ProfileJob
      try {
        $reply=$job.Request.Task.GetAwaiter().GetResult()
        if($reply.Status -ne 200) { throw 'Profile unavailable.' }
        $path=Get-UsageAuthPath $job.Id
        $profile=Get-AuthProfileInfo $path
        if(-not $profile -or $profile.Identity -cne $job.Identity) { throw 'Login changed.' }
        if($job.Stage -eq 'Profile') {
          $data=$reply.Json | ConvertFrom-Json -ErrorAction Stop
          if(-not $data.id -or -not $data.email -or -not $job.Email -or $data.email -ine $job.Email) {
            throw 'Profile identity did not match.'
          }
          if($data.picture) {
            $uri=[uri]$data.picture
            if(-not [CGS.UsageRequest]::SupportsPicture($uri)) { throw 'Unsupported profile image address.' }
            $auth=[IO.File]::ReadAllText($path) | ConvertFrom-Json
            $job.Request.Dispose()
            $job.Request=New-ProfileRequest ([string]$auth.tokens.access_token) ([string]$auth.tokens.account_id) $uri
            $job.Stage='Image'
            return
          }
          $bitmap=$null
        } else { $bitmap=Convert-ProfilePicture $reply.Bytes }
        $script:ProfileCache[$job.Id]=@{Identity=$job.Identity;Image=$bitmap;Checked=[DateTime]::Now}
        Set-ProfileAvatar $job.Id
      } catch {
        # A failed or unverified profile keeps the account's own safe fallback.
        Set-ProfileAvatar $job.Id
      }
      Stop-ProfileRefresh
      Invoke-NextProfileRefresh
    })
    $script:ProfileTimer=$timer; $timer.Start()
  } catch {
    Stop-ProfileRefresh
    Set-ProfileAvatar $Id
    Invoke-NextProfileRefresh
  }
}


function Set-UsageCard {
  param([string]$Id,$Usage,[string]$Message)
  if(-not $script:UsageCards -or -not $script:UsageCards.ContainsKey($Id)) { return }
  $card=$script:UsageCards[$Id]
  foreach($key in @('FiveHour','Weekly')) {
    $meter=$card[$key]; $window=if($Usage){$Usage.$key}else{$null}
    if($window) {
      $meter.Text.Text=('{0}  {1:0}% left' -f $meter.Label,$window.Remaining)
      $meter.Column.Width=[Windows.GridLength]::new($window.Remaining,[Windows.GridUnitType]::Star)
      $meter.OtherColumn.Width=[Windows.GridLength]::new((100-$window.Remaining),[Windows.GridUnitType]::Star)
      $meter.Fill.Background=$(if($window.Remaining -le 10){'#DCA0A0'}else{'#BDBDBD'})
      $meter.Text.ToolTip=if($window.Reset){'Resets '+$window.Reset.ToString('ddd, MMM d · h:mm tt')}else{'Reset time unavailable'}
    } else {
      $meter.Text.Text=$meter.Label+'  —'; $meter.Column.Width='0*'; $meter.OtherColumn.Width='100*'
      $meter.Text.ToolTip='This usage window is unavailable.'
    }
  }
  $card.Feedback.Text=if($Message){$Message}elseif($Usage){'Updated '+$Usage.Updated.ToString('h:mm tt')}else{'Refresh to load limits'}
  $card.Feedback.ToolTip=$card.Feedback.Text
}

function Stop-UsageRefresh {
  if($script:UsageTimer) { $script:UsageTimer.Stop(); $script:UsageTimer=$null }
  if($script:UsageJob) { $script:UsageJob.Request.Dispose(); $script:UsageJob=$null }
  foreach($card in @($script:UsageCards.Values)) {
    if($card) { [CGS.Motion]::Busy($card.Refresh.Content.Children[0],$false) }
  }
}

function Invoke-NextUsageRefresh {
  if($script:UsageJob -or $script:LaunchBusy -or -not $script:PickerForm -or -not $script:PickerForm.IsVisible) { return }
  if(@($script:UsageQueue).Count -eq 0) { return }
  $id=$script:UsageQueue[0]
  $script:UsageQueue=@($script:UsageQueue | Select-Object -Skip 1)
  Invoke-UsageRefresh $id
}

function Queue-VisibleUsageRefresh {
  $script:UsageQueue=@()
  foreach($id in @($script:UsageCards.Keys)) {
    $card=$script:UsageCards[$id].Surface
    $position=$card.TranslatePoint([Windows.Point]::new(0,0),$script:PickerScroll)
    if($position.Y -ge $script:PickerScroll.ViewportHeight -or $position.Y+$card.ActualHeight -le 0) { continue }
    $profile=Get-AuthProfileInfo (Get-UsageAuthPath $id)
    if(-not $profile -or $profile.Kind -ne 'chatgpt') { continue }
    $cached=$script:UsageCache[$id]
    if($cached -and $cached.Identity -ceq $profile.Identity -and ([DateTime]::Now-$cached.Usage.Updated).TotalMinutes -lt 1) { continue }
    $script:UsageQueue+=@($id)
  }
  Invoke-NextUsageRefresh
}

function Invoke-UsageRefresh {
  param([string]$Id)
  if($script:UsageJob -or $script:LaunchBusy) { return }
  try {
    Ensure-UsageClient
    $authPath=Get-UsageAuthPath $Id
    $profile=Get-AuthProfileInfo $authPath
    if(-not $profile -or $profile.Kind -ne 'chatgpt') { throw 'Save a ChatGPT login to view limits.' }
    $auth=[IO.File]::ReadAllText($authPath) | ConvertFrom-Json
    if(-not $auth.tokens.access_token -or -not $auth.tokens.account_id) { throw 'Open the account and save its login again.' }
    $request=[CGS.UsageRequest]::new([string]$auth.tokens.access_token,[string]$auth.tokens.account_id)
    $script:UsageJob=@{Id=$Id;Identity=$profile.Identity;AccountId=[string]$auth.tokens.account_id;Request=$request}
    foreach($card in $script:UsageCards.Values) { $card.Refresh.IsEnabled=$false }
    $card=$script:UsageCards[$Id]
    if($card) { $card.Feedback.Text='Refreshing…'; [CGS.Motion]::Busy($card.Refresh.Content.Children[0],$true) }
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(80)
    $timer.add_Tick({
      if(-not $script:UsageJob -or -not $script:UsageJob.Request.Task.IsCompleted) { return }
      $job=$script:UsageJob
      try {
        $reply=$job.Request.Task.GetAwaiter().GetResult()
        if($reply.Status -ne 200) {
          $message=switch($reply.Status) {
            401 {'Login expired. Open the account and save its login again.'}
            403 {'Usage is unavailable for this login.'}
            429 {'Too many requests. Try again shortly.'}
            default {'Could not refresh. Try again.'}
          }
          throw $message
        }
        $usage=Convert-UsagePayload $reply.Json $job.AccountId
        $profile=Get-AuthProfileInfo (Get-UsageAuthPath $job.Id)
        if($profile -and $profile.Identity -ceq $job.Identity) {
          $script:UsageCache[$job.Id]=@{Identity=$job.Identity;Usage=$usage}
          Set-UsageCard $job.Id $usage
        } else { Set-UsageCard $job.Id $null 'Login changed. Refresh again.' }
      } catch {
        $cached=$script:UsageCache[$job.Id]
        $current=Get-AuthProfileInfo (Get-UsageAuthPath $job.Id)
        if(-not $current -or -not $cached -or $cached.Identity -cne $current.Identity) { $cached=$null }
        Set-UsageCard $job.Id $(if($cached){$cached.Usage}else{$null}) 'Could not refresh. Hover for details.'
        if($script:UsageCards.ContainsKey($job.Id)) { $script:UsageCards[$job.Id].Feedback.ToolTip=$_.Exception.Message }
      } finally {
        Stop-UsageRefresh
        foreach($card in $script:UsageCards.Values) { $card.Refresh.IsEnabled=-not $script:LaunchBusy }
      }
      Invoke-NextUsageRefresh
    })
    $script:UsageTimer=$timer; $timer.Start()
  } catch {
    $message=if($_.Exception.Message -in @('Save a ChatGPT login to view limits.','Open the account and save its login again.')){$_.Exception.Message}else{'Could not refresh. Try again.'}
    Set-UsageCard $Id $null $message
    Stop-UsageRefresh
    foreach($card in $script:UsageCards.Values) { $card.Refresh.IsEnabled=-not $script:LaunchBusy }
    Invoke-NextUsageRefresh
  }
}


function Update-PickerRows {
  if(-not $script:PickerPanel) { return }
  $focused=[Windows.Input.Keyboard]::FocusedElement
  $focusId=if($focused -is [Windows.Controls.Button]) { $focused.Tag } else { $null }
  $script:ProfileQueue=@(); Stop-ProfileRefresh
  $script:UsageQueue=@(); Stop-UsageRefresh
  $script:UsageCards=@{}
  if(-not $script:UsageCache) { $script:UsageCache=@{} }
  if(-not $script:ProfileCache) { $script:ProfileCache=@{} }
  $script:PickerPanel.Children.Clear(); $script:LaunchButtons=@(); $script:OptionButtons=@(); $script:StatusBadges=@{}
  $cfg=Get-Config
  $rows=@([pscustomobject]@{id=$script:MainId;display=(Get-ManagedAccount $script:MainId).display;mode='main'}) + @($cfg.accounts)
  $script:AccountCount.Text=('{0} {1}' -f $rows.Count,$(if($rows.Count -eq 1){'account'}else{'accounts'}))
  foreach($r in $rows) {
    $mode=if($r.id -eq $script:MainId){'main'}elseif($r.mode -eq 'shared'){'shared'}else{'isolated'}
    $card=New-Object Windows.Controls.Border; $card.CornerRadius=12; $card.BorderThickness=1; $card.Padding='20'; $card.Margin='0,0,0,12'; $card.MinHeight=112
    [CGS.Motion]::Card($card)
    $grid=New-Object Windows.Controls.Grid
    foreach($height in @('Auto','Auto')) { $row=New-Object Windows.Controls.RowDefinition; $row.Height=$height; [void]$grid.RowDefinitions.Add($row) }
    foreach($width in @('Auto','*','Auto')) { $c=New-Object Windows.Controls.ColumnDefinition; $c.Width=$width; [void]$grid.ColumnDefinitions.Add($c) }
    $avatar=New-Object Windows.Controls.Border; $avatar.Width=40; $avatar.Height=40; $avatar.CornerRadius=12; $avatar.Background='#252525'; $avatar.BorderBrush='#303030'; $avatar.BorderThickness=1; $avatar.VerticalAlignment='Center'; $avatar.Margin='0,0,16,0'
    $display=[string]$r.display; $initial=if($display.Length){[Globalization.StringInfo]::GetNextTextElement($display).ToUpperInvariant()}else{'?'}
    $letter=New-UiText $initial 16 '#D8D8D8'; $letter.HorizontalAlignment='Center'; $letter.VerticalAlignment='Center'; $letter.FontWeight='Medium'; $avatar.Child=$letter; [void]$grid.Children.Add($avatar)
    $details=New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($details,1); $details.Margin='0,0,16,0'; $details.VerticalAlignment='Center'
    $name=New-UiText $display 16 '#E6E6E6'; $name.FontWeight='Medium'; $name.TextWrapping='NoWrap'; $name.TextTrimming='CharacterEllipsis'; $name.ToolTip=$display; [void]$details.Children.Add($name)
    $email=New-UiText '' 12 '#A0A0A0'
    $email.Margin='0,3,0,0'; $email.TextWrapping='NoWrap'; $email.TextTrimming='CharacterEllipsis'
    [void]$details.Children.Add($email)
    $meta=New-Object Windows.Controls.WrapPanel; $meta.Margin='0,7,0,0'
    $modeLabel=switch($mode){'main'{'Main session'} 'shared'{'Shared projects'} default{'Isolated'}}
    $modeText=New-UiText $modeLabel 12 '#A0A0A0'; $modeText.Margin='0,0,12,0'; [void]$meta.Children.Add($modeText)
    $status=New-Object Windows.Controls.StackPanel; $status.Orientation='Horizontal'; $status.VerticalAlignment='Center'; $status.Margin='0'
    $dot=New-Object Windows.Shapes.Ellipse; $dot.Width=5; $dot.Height=5; $dot.Fill='#737373'; $dot.Margin='0,0,8,0'; $dot.VerticalAlignment='Center'; [void]$status.Children.Add($dot)
    $badge=New-UiText 'Not running' 12 '#909090'; $badge.VerticalAlignment='Center'; [void]$status.Children.Add($badge); [void]$meta.Children.Add($status)
    $script:StatusBadges[$r.id]=@{Text=$badge;Email=$email;Dot=$dot;Mode=$mode;Running=$null;Selected=$null;Avatar=$avatar;Initial=$letter}
    [void]$details.Children.Add($meta); [void]$grid.Children.Add($details)
    $actions=New-Object Windows.Controls.StackPanel; $actions.Orientation='Horizontal'; $actions.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($actions,2)
    $openTip=if($mode -in @('main','shared')){'Open this account. ChatGPT will restart if needed to switch logins.'}else{('Open {0} using its existing session.' -f $display)}
    $open=New-UiButton 'Open' 'arrow' -Tip $openTip; $open.Tag=$r.id; $open.MinWidth=104; $open.Width=104; $open.MinHeight=40; $open.FontSize=12; $open.Padding='12,8'
    [Windows.Automation.AutomationProperties]::SetName($open,('Open '+$display))
    $open.add_Click({ param($sender,$e) Invoke-UiLaunch $sender.Tag }); [void]$actions.Children.Add($open); $script:LaunchButtons+=@($open)
    $options=New-UiButton 'Account options' 'more' -Quiet -IconOnly -Tip ('Account options for '+$display)
    [Windows.Automation.AutomationProperties]::SetName($options,('Account options for '+$display))
    $options.Tag=$r.id; $options.Width=40; $options.Height=40; $options.Padding=0; $options.Margin='4,0,0,0'
    $options.HorizontalContentAlignment='Center'; $options.VerticalContentAlignment='Center'
    $cm=New-UiMenu
    if($mode -in @('main','shared')) {
      $saveLabel=if($mode -eq 'main' -and $display -eq 'Main'){'Save current login as Main'}else{'Save current login'}
      Add-UiMenuItem $cm $saveLabel 'save' 'save' $r.id
    }
    Add-UiMenuItem $cm 'Create desktop shortcut' 'link' 'shortcut' $r.id
    Add-UiMenuItem $cm 'Rename account' 'edit' 'rename' $r.id
    if($mode -ne 'main') { Add-UiMenuItem $cm 'Remove account…' 'trash' 'remove' $r.id }
    $card.ContextMenu=$cm; $options.ContextMenu=$cm
    $options.add_Click({
      param($sender,$e)
      $sender.ContextMenu.PlacementTarget=$sender
      $sender.ContextMenu.Placement='Custom'
      $sender.ContextMenu.IsOpen=$true
    })
    [void]$actions.Children.Add($options); $script:OptionButtons+=@($options)
    [void]$grid.Children.Add($actions)
    $usagePanel=New-Object Windows.Controls.Grid; $usagePanel.Margin='0,14,0,0'
    [Windows.Controls.Grid]::SetRow($usagePanel,1); [Windows.Controls.Grid]::SetColumnSpan($usagePanel,3)
    foreach($width in @('*','*','40')) { $column=New-Object Windows.Controls.ColumnDefinition; $column.Width=$width; [void]$usagePanel.ColumnDefinitions.Add($column) }
    $fiveHour=New-UsageMeter '5h'; $fiveHour.Panel.Margin='0,0,20,0'; [void]$usagePanel.Children.Add($fiveHour.Panel)
    $weekly=New-UsageMeter 'Weekly'; $weekly.Panel.Margin='0,0,16,0'
    [Windows.Controls.Grid]::SetColumn($weekly.Panel,1); [void]$usagePanel.Children.Add($weekly.Panel)
    $refresh=New-UiButton 'Refresh limits' 'refresh' -Quiet -IconOnly -Tip 'Refresh the five-hour and weekly Codex limits for this account.'
    $refresh.Width=32; $refresh.Height=32; $refresh.MinHeight=32; $refresh.Padding=0; $refresh.Tag=$r.id
    [Windows.Controls.Grid]::SetColumn($refresh,2); $refresh.HorizontalAlignment='Right'
    $refresh.add_Click({ param($sender,$e) Invoke-UsageRefresh $sender.Tag; Invoke-ProfileRefresh $sender.Tag })
    [void]$usagePanel.Children.Add($refresh)
    $feedback=New-UiText 'Refresh to load limits' 11 '#909090'
    $feedback.TextWrapping='NoWrap'; $feedback.TextTrimming='CharacterEllipsis'; $feedback.Margin='0,7,0,0'
    $feedbackPanel=New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetRow($feedbackPanel,1); [Windows.Controls.Grid]::SetColumnSpan($feedbackPanel,3)
    # The footer has its own vertical flow so loading feedback never shifts actions.
    $usagePanel.Margin=0; [void]$feedbackPanel.Children.Add($usagePanel); [void]$feedbackPanel.Children.Add($feedback)
    $feedbackPanel.Margin='0,14,0,0'; [void]$grid.Children.Add($feedbackPanel)
    $script:UsageCards[$r.id]=@{FiveHour=$fiveHour;Weekly=$weekly;Refresh=$refresh;Feedback=$feedback;Surface=$card}
    $cached=$script:UsageCache[$r.id]
    $usageProfile=Get-AuthProfileInfo (Get-UsageAuthPath $r.id)
    if($cached -and $usageProfile -and $cached.Identity -ceq $usageProfile.Identity) { Set-UsageCard $r.id $cached.Usage }
    Set-ProfileAvatar $r.id
    $card.Child=$grid; [void]$script:PickerPanel.Children.Add($card)
  }
  Update-PickerStatus
  if($focusId) { foreach($b in $script:LaunchButtons) { if($b.Tag -eq $focusId) { [void]$b.Focus(); break } } }
}

function Update-PickerStatus {
  if(-not $script:PickerPanel -or $script:LaunchBusy) { return }
  $running=@(Get-RunningAccountIds)
  $current=Get-AuthProfileInfo (Join-Path (Get-RealCodexHome) 'auth.json')
  $activeShared=Get-ActiveShared
  foreach($id in @($script:StatusBadges.Keys)) {
    $d=$script:StatusBadges[$id]; $selected=$false; $live=$false
    if($d.Mode -in @('main','shared')) {
      $account=Get-ManagedAccount $id; $stored=if($account){Get-AuthProfileInfo (Get-SharedAuthStore $account)}else{$null}
      $selected=($stored -and $current -and $stored.Identity -ceq $current.Identity)
      $live=$selected -and $running -contains $script:MainId
      $label=if(-not $stored){'Login not saved'}elseif($selected){'Current login'+$(if($live){' · App running'}else{''})}else{'Login saved'}
      $d.Text.ToolTip='Current login matches the saved authentication file. The desktop app must be fully restarted for an account change; this does not inspect its live UI.'
      $profile=$stored
      if($d.Mode -eq 'main' -and -not $stored -and -not $activeShared) { $profile=$current }
    } else {
      $live=$running -contains $id; $label=if($live){'Running'}else{'Not running'}
      $profile=Get-AuthProfileInfo (Join-Path (Get-AccountPaths $id).Codex 'auth.json')
    }
    $emailLabel=if($profile -and $profile.Email){$profile.Email}else{'Email unavailable'}
    if($d.Email.Text -cne $emailLabel) { $d.Email.Text=$emailLabel; $d.Email.ToolTip=$emailLabel }
    $d.Text.Text=$label
    if($null -ne $d.Running -and ($d.Running -ne $live -or $d.Selected -ne $selected)) { [CGS.Motion]::Status($d.Text,$d.Text.Foreground,$live) }
    else { $d.Text.Foreground=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($(if($live){'#59B99A'}else{'#909090'}))) }
    $d.Dot.Fill=$d.Text.Foreground; $d.Dot.Opacity=$(if($live){1.0}else{0.7})
    $d.Running=$live; $d.Selected=$selected
  }
}

function Set-UiBusy {
  param([bool]$Busy,[string]$Id)
  foreach($b in @($script:LaunchButtons)) {
    if($null -eq $b) { continue }
    $b.IsEnabled=-not $Busy
    if($b.Tag -eq $Id) {
      $label=$b.Content.Children[$b.Content.Children.Count-1]; $label.Text=$(if($Busy){'Opening…'}else{'Open'})
      $icon=$b.Content.Children[0]
      $surface=$null; if($b.Template) { $surface=$b.Template.FindName('Surface',$b) }
      if($surface) { if($Busy) { $surface.Opacity=1 } else { $surface.ClearValue([Windows.UIElement]::OpacityProperty) } }
      if($Busy) { $icon.Data=(New-UiIcon 'spinner').Data; [CGS.Motion]::Busy($icon,$true) }
      else { [CGS.Motion]::Busy($icon,$false); $icon.Data=(New-UiIcon 'arrow').Data }
    }
  }
  foreach($usageCard in @($script:UsageCards.Values)) { if($usageCard) { $usageCard.Refresh.IsEnabled=(-not $Busy -and -not $script:UsageJob) } }
  foreach($b in @($script:OptionButtons)+@($script:AddButton)+@($script:SettingsActions)) { if($b) { $b.IsEnabled=-not $Busy; if($b.ContextMenu) { $b.ContextMenu.IsOpen=$false } } }
  if($script:PickerPanel) { foreach($card in $script:PickerPanel.Children) { if($card.ContextMenu) { $card.ContextMenu.IsEnabled=-not $Busy; $card.ContextMenu.IsOpen=$false } } }
  if($script:PickerHint) { $script:PickerHint.Text='Isolated accounts can run together. Shared projects open one at a time.' }
}

function Invoke-UiLaunch {
  param([string]$Id)
  if($script:LaunchBusy) { return }
  Ensure-Gui
  $script:ProfileQueue=@(); Stop-ProfileRefresh
  $script:UsageQueue=@(); Stop-UsageRefresh
  $script:LaunchBusy=$true; $script:LaunchingId=$Id
  try {
    Set-UiBusy $true $Id
    $state=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $functions=@('Write-Log','Get-SafeName','Get-ChatGptApp','Get-Config','Save-Config','Get-AccountPaths','Find-Account',
      'Start-Account','Get-RealCodexHome','Get-SharedAuthStore','Test-RealHomeInstanceRunning','Get-ActiveShared','Set-ActiveShared','Save-CurrentAuthToAccount','Start-SharedAccount',
      'Get-MainAuthStore','Get-ManagedAccount','Get-AuthProfileInfo','Copy-AuthFileAtomic','Enter-AuthOperation','Assert-FileAuthStorage','Get-SharedHomeProcesses','Close-SharedDesktopApp','Start-DefaultDesktopApp','Wait-DesktopAppStart')
    foreach($name in $functions) { $state.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name,(Get-Command $name -CommandType Function).Definition)) }
    $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($state); $runspace.ApartmentState='STA'; $runspace.ThreadOptions='ReuseThread'; $runspace.Open()
    $ps=[Management.Automation.PowerShell]::Create(); $ps.Runspace=$runspace
    [void]$ps.AddScript({ param($id,$root,$path,$main)
      $ErrorActionPreference='Stop'; $script:Root=$root; $script:ConfigPath=Join-Path $root 'accounts.json'; $script:LogPath=Join-Path $root 'switcher.log'
      $script:ScriptPath=$path; $script:MainId=$main; $script:AppCache=$null
      try { Start-Account $id $true; [pscustomobject]@{Success=$true;Message=''} }
      catch { [pscustomobject]@{Success=$false;Message=$_.Exception.Message} }
    }).AddArgument($Id).AddArgument($script:Root).AddArgument($script:ScriptPath).AddArgument($script:MainId)
    $handle=$ps.BeginInvoke()
    $script:LaunchJob=@{PowerShell=$ps;Runspace=$runspace;Handle=$handle}
    $timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromMilliseconds(60)
    $timer.add_Tick({
      if(-not $script:LaunchJob -or -not $script:LaunchJob.Handle.IsCompleted) { return }
      $script:LaunchTimer.Stop()
      $job=$script:LaunchJob; $script:LaunchJob=$null
      try {
        $output=@($job.PowerShell.EndInvoke($job.Handle)); $result=$output | Where-Object { $_.PSObject.Properties['Success'] } | Select-Object -Last 1
        if(-not $result) { throw 'The account launcher did not return a result.' }
      } catch { $result=[pscustomobject]@{Success=$false;Message=$_.Exception.Message} }
      finally { $job.PowerShell.Dispose(); $job.Runspace.Dispose() }
      $script:LaunchBusy=$false
      $script:LaunchTimer=$null
      try {
        Set-UiBusy $false $script:LaunchingId
        if($result.Success) {
          Update-PickerStatus
          if($script:PickerHint) { $script:PickerHint.Text='Account opened.' }
        } else {
          Show-Message $result.Message 'Could not open account' 'Error'
        }
        if($script:CloseAfterLaunch -and $script:PickerForm) { $script:PickerForm.Close() }
        else { foreach($b in $script:LaunchButtons) { if($b.Tag -eq $script:LaunchingId) { [void]$b.Focus(); break } } }
      } catch {
        Write-Log ('UI launch completion error: '+$_.Exception.Message)
        Set-UiBusy $false $script:LaunchingId
        Show-Message 'The launch result could not be displayed. The picker has recovered; check the desktop app before retrying.' 'Launch feedback error' 'Error'
      }
      if($script:TrayExitPending) { [Windows.Forms.Application]::Exit() }
    })
    $script:LaunchTimer=$timer; $timer.Start()
  } catch {
    if($ps) { $ps.Dispose() }; if($runspace) { $runspace.Dispose() }
    $script:LaunchBusy=$false; Set-UiBusy $false $Id
    Show-Message $_.Exception.Message 'Could not open account' 'Error'
  }
}


function Get-SafeName {
  param([string]$Name)
  $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
  $re = '[{0}]' -f [regex]::Escape($invalid)
  $s = ($Name -replace $re, '_').Trim()
  $s = $s -replace '\s+', '_'
  if ([string]::IsNullOrWhiteSpace($s) -or $s -in @('.','..')) { $s = 'account' }
  return $s
}

# ------------------------------------------------------------------ アプリ検出

function Get-ChatGptApp {
  if ($script:AppCache) { return $script:AppCache }

  # Microsoft Store (MSIX) 版: OpenAI.Codex_2p2nqsd0c76g0  ※現在の「ChatGPT」デスクトップアプリ
  $pkg = $null
  try {
    if ($PSVersionTable.PSEdition -eq 'Core') { Import-Module Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
      Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
  } catch {}

  if ($pkg) {
    $loc = $pkg.InstallLocation
    $exe = $null
    foreach ($cand in @((Join-Path $loc 'ChatGPT.exe'), (Join-Path $loc 'app\ChatGPT.exe'), (Join-Path $loc 'Codex.exe'))) {
      if (Test-Path -LiteralPath $cand) { $exe = $cand; break }
    }
    if (-not $exe) {
      $found = Get-ChildItem -LiteralPath $loc -Filter 'ChatGPT.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($found) { $exe = $found.FullName }
    }
    $appId = $null
    try {
      $manifest = Get-AppxPackageManifest -Package $pkg
      $appId = @($manifest.Package.Applications.Application)[0].Id
    } catch {}
    $script:AppCache = [pscustomobject]@{
      Kind              = 'Store'
      Exe               = $exe
      PackageFamilyName = $pkg.PackageFamilyName
      AppId             = $appId
      Version           = $pkg.Version
      InstallLocation   = $loc
    }
    return $script:AppCache
  }

  # 通常インストーラー版（念のため）
  foreach ($c in @(
      (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\ChatGPT.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe'),
      (Join-Path $env:ProgramFiles 'ChatGPT\ChatGPT.exe'))) {
    if (Test-Path -LiteralPath $c) {
      $script:AppCache = [pscustomobject]@{
        Kind = 'Installer'; Exe = $c; PackageFamilyName = $null; AppId = $null
        Version = (Get-Item -LiteralPath $c).VersionInfo.ProductVersion
        InstallLocation = (Split-Path -Parent $c)
      }
      return $script:AppCache
    }
  }
  return $null
}

# ------------------------------------------------------------------ 設定

function Get-Config {
  $cfg = $null
  if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
      $raw = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
      $cfg = $raw | ConvertFrom-Json
    } catch { Write-Log "config read error: $_" }
  }
  if (-not $cfg) { $cfg = [pscustomobject]@{ accounts = @() } }
  if (-not ($cfg.PSObject.Properties.Name -contains 'accounts')) {
    $cfg | Add-Member -NotePropertyName accounts -NotePropertyValue @() -Force
  }
  $cfg.accounts = @($cfg.accounts | Where-Object { $_ -ne $null })
  return $cfg
}

function Save-Config {
  param($Config)
  New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
  $Config.accounts = @($Config.accounts)
  $json = ConvertTo-Json -InputObject $Config -Depth 5
  [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AccountPaths {
  param([string]$Id)
  $rootPath=[IO.Path]::GetFullPath($script:Root).TrimEnd('\')
  $base=[IO.Path]::GetFullPath((Join-Path $rootPath $Id))
  if(-not $base.StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'The account data path is outside the account folder.' }
  return [pscustomobject]@{
    Base     = $base
    Electron = (Join-Path $base 'electron')
    Codex    = (Join-Path $base 'codex')
  }
}

function Find-Account {
  param([string]$Key)   # ID でも表示名でもOK
  $cfg = Get-Config
  $acc = $cfg.accounts | Where-Object { $_.id -eq $Key } | Select-Object -First 1
  if (-not $acc) { $acc = $cfg.accounts | Where-Object { $_.display -eq $Key } | Select-Object -First 1 }
  if (-not $acc) { $acc = $cfg.accounts | Where-Object { $_.id -eq (Get-SafeName $Key) } | Select-Object -First 1 }
  return $acc
}

function Add-Account {
  param([string]$Display, [switch]$SkipShortcut, [switch]$Shared)
  $Display = $Display.Trim()
  if ([string]::IsNullOrWhiteSpace($Display)) { throw 'Enter an account name.' }
  $cfg = Get-Config
  if ($cfg.accounts | Where-Object { $_.display -eq $Display }) { throw "An account named `"$Display`" already exists." }
  $id = Get-SafeName $Display
  $n = 2
  while ($id -eq $script:MainId -or ($cfg.accounts | Where-Object { $_.id -eq $id })) { $id = (Get-SafeName $Display) + "_$n"; $n++ }
  $color = $script:Palette[ $cfg.accounts.Count % $script:Palette.Count ]
  $acc = [pscustomobject]@{
    id      = $id
    display = $Display
    color   = $color
    created = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    mode    = $(if ($Shared) { 'shared' } else { 'isolated' })
  }
  $cfg.accounts = @($cfg.accounts) + @($acc)
  Save-Config $cfg
  $p = Get-AccountPaths $id
  New-Item -ItemType Directory -Force -Path $p.Electron, $p.Codex | Out-Null
  Write-Log "account added: $id ($Display)"
  if (-not $SkipShortcut) { New-AccountShortcut -Account $acc | Out-Null }
  Set-JumpList
  return $acc
}

function Remove-Account {
  param([string]$Key)
  $acc = Find-Account $Key
  if (-not $acc) { throw "Account `"$Key`" was not found." }
  if ((Get-RunningAccountIds) -contains $acc.id) { throw "`"$($acc.display)`" is running. Close its app window first." }
  $p = Get-AccountPaths $acc.id
  if (Test-Path -LiteralPath $p.Base) { Remove-Item -LiteralPath $p.Base -Recurse -Force }
  $cfg = Get-Config
  $cfg.accounts = @($cfg.accounts | Where-Object { $_.id -ne $acc.id })
  Save-Config $cfg
  $lnk = Get-AccountShortcutPath $acc
  if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
  Write-Log "account removed: $($acc.id)"
  Set-JumpList
}

function Rename-Account {
  param([string]$Key, [string]$NewDisplay)
  $acc = Get-ManagedAccount $Key
  if (-not $acc) { throw "Account `"$Key`" was not found." }
  $NewDisplay = $NewDisplay.Trim()
  if ([string]::IsNullOrWhiteSpace($NewDisplay)) { return }
  $old = Get-AccountShortcutPath $acc
  $cfg = Get-Config
  if($acc.display -ceq $NewDisplay) { return }
  $shortcutName=Get-SafeName $NewDisplay
  $otherAccounts=@($cfg.accounts) + @((Get-ManagedAccount $script:MainId))
  if($otherAccounts | Where-Object { $_.id -ne $acc.id -and (Get-SafeName $_.display) -eq $shortcutName }) {
    throw 'Choose a name that is different from your other accounts.'
  }
  if($acc.id -eq $script:MainId) {
    $cfg | Add-Member -NotePropertyName mainDisplay -NotePropertyValue $NewDisplay -Force
  } else {
    foreach($a in $cfg.accounts) { if($a.id -eq $acc.id) { $a.display=$NewDisplay } }
  }
  Save-Config $cfg
  if (Test-Path -LiteralPath $old) {
    Remove-Item -LiteralPath $old -Force
    New-AccountShortcut -Account (Get-ManagedAccount $acc.id) | Out-Null
  }
  Set-JumpList
}

# ------------------------------------------------------------------ 起動

function Get-RunningAccountIds {
  $ids = @()
  $procs = @()
  try { $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe' OR Name = 'Codex.exe'" -ErrorAction SilentlyContinue) } catch {}
  if ($procs.Count -eq 0) { return $ids }
  $cfg = Get-Config
  foreach ($acc in $cfg.accounts) {
    $p = Get-AccountPaths $acc.id
    $hit = $procs | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($p.Electron, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
    if ($hit) { $ids += $acc.id }
  }
  $mainHit = $procs | Where-Object {
    $_.CommandLine -and ($_.CommandLine -notmatch '--user-data-dir=') -and ($_.CommandLine -notmatch '--type=')
  } | Select-Object -First 1
  if ($mainHit) { $ids += $script:MainId }
  return $ids
}

function Start-Account {
  param([string]$Id,[bool]$RestartDesktop=$false)
  $app = Get-ChatGptApp
  if (-not $app) { throw 'The ChatGPT desktop app was not found. Install the supported desktop app from Microsoft Store.' }

  if ($Id -eq $script:MainId) {
    if(Test-Path -LiteralPath (Get-MainAuthStore)) { Start-SharedAccount (Get-ManagedAccount $script:MainId) $RestartDesktop; return }
    if(Get-ActiveShared) { throw 'Main has no separately saved login. Use Main > Account options > Save current login as Main after confirming that the desktop app is signed into your intended Main account.' }
    Start-DefaultDesktopApp $app
    Write-Log 'launched: current main session (no saved Main profile)'
    return
  }

  $acc = Find-Account $Id
  if (-not $acc) { throw "Account `"$Id`" is not registered." }

  # 完全共有モード: 実の ~/.codex を使い、auth.json だけ差し替える（1アカウントずつ）
  if ($acc.mode -eq 'shared') { Start-SharedAccount $acc $RestartDesktop; return }

  if (-not $app.Exe) { throw "ChatGPT.exe was not found in $($app.InstallLocation)." }

  $p = Get-AccountPaths $acc.id
  New-Item -ItemType Directory -Force -Path $p.Electron, $p.Codex | Out-Null

  # アカウント分離の要: Electron のユーザーデータ (Cookie/ログイン) と Codex のホーム
  $env:CODEX_HOME = $p.Codex
  $env:CODEX_ELECTRON_USER_DATA_PATH = $p.Electron
  $arg = '--user-data-dir="' + $p.Electron + '"'

  try {
    Start-Process -FilePath $app.Exe -ArgumentList $arg -WorkingDirectory $p.Base
    Write-Log "launched: $($acc.id) via direct exe"
  } catch {
    Write-Log "direct launch failed: $_"
    if ($app.Kind -eq 'Store' -and $app.AppId -and (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) {
      Invoke-CommandInDesktopPackage -PackageFamilyName $app.PackageFamilyName -AppId $app.AppId -Command $app.Exe -Args $arg -PreventBreakaway
      Write-Log "launched: $($acc.id) via Invoke-CommandInDesktopPackage"
    } else { throw }
  }
}

# ------------------------------------------------------------------ 完全共有モード（実 ~/.codex + auth.json 差し替え）

function Get-RealCodexHome { return (Join-Path $env:USERPROFILE '.codex') }

function Get-ActiveShared {
  $cfg = Get-Config
  if ($cfg.PSObject.Properties.Name -contains 'activeShared') { return $cfg.activeShared }
  return $null
}
function Set-ActiveShared {
  param([string]$Id)
  $cfg = Get-Config
  $cfg | Add-Member -NotePropertyName activeShared -NotePropertyValue $Id -Force
  Save-Config $cfg
}

# 現在の ~/.codex/auth.json を、指定アカウントの保存先に取り込む（ログイン後の保存にも使う）
function Get-MainAuthStore { return (Join-Path $script:Root 'main-auth.json') }

function Get-ManagedAccount {
  param([string]$Id)
  if($Id -eq $script:MainId) {
    $display=(Get-Config).mainDisplay
    if([string]::IsNullOrWhiteSpace($display)) { $display='Main' }
    return [pscustomobject]@{id=$script:MainId;display=$display;mode='shared'}
  }
  return (Find-Account $Id)
}

function Get-SharedAuthStore {
  param($Account)
  if($Account.id -eq $script:MainId) { return (Get-MainAuthStore) }
  return (Join-Path (Get-AccountPaths $Account.id).Base 'shared-auth.json')
}

function Get-AuthProfileInfo {
  param([string]$Path,[byte[]]$Bytes)
  try {
    if(-not $Bytes) { if(-not (Test-Path -LiteralPath $Path)) { return $null }; $Bytes=[IO.File]::ReadAllBytes($Path) }
    $data=[Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    if($data.tokens -and $data.tokens.id_token) {
      $parts=([string]$data.tokens.id_token).Split('.')
      if($parts.Count -ne 3) { return $null }
      $encoded=$parts[1].Replace('-','+').Replace('_','/'); $encoded=$encoded.PadRight($encoded.Length+((4-$encoded.Length%4)%4),'=')
      $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
      if(-not $claims.sub -or -not $data.tokens.account_id) { return $null }
      return [pscustomobject]@{Identity=([string]$claims.sub+'|'+[string]$data.tokens.account_id);Email=[string]$claims.email;Kind='chatgpt'}
    }
    if($data.OPENAI_API_KEY) {
      $sha=[Security.Cryptography.SHA256]::Create()
      try { $digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$data.OPENAI_API_KEY))).Replace('-','') } finally { $sha.Dispose() }
      return [pscustomobject]@{Identity=('api:'+ $digest);Email='API key login';Kind='api'}
    }
  } catch { return $null }
  return $null
}

function Copy-AuthFileAtomic {
  param([string]$Source,[string]$Destination,[string]$Backup)
  $bytes=[IO.File]::ReadAllBytes($Source)
  if(-not (Get-AuthProfileInfo -Bytes $bytes)) { throw 'The login file is incomplete or unsupported. Finish signing in, then save the login again.' }
  $directory=Split-Path -Parent $Destination
  [void][IO.Directory]::CreateDirectory($directory)
  $temporary=Join-Path $directory ('.switcher-'+[guid]::NewGuid().ToString('N')+'.tmp')
  try {
    [IO.File]::WriteAllBytes($temporary,$bytes)
    if([IO.File]::Exists($Destination)) { if($Backup) { [IO.File]::Replace($temporary,$Destination,$Backup) } else { [IO.File]::Replace($temporary,$Destination,[NullString]::Value) } }
    else { [IO.File]::Move($temporary,$Destination) }
  } finally { if([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Enter-AuthOperation {
  $mutex=[Threading.Mutex]::new($false,'Local\Alyawmu.ChatGPTSwitcher.SharedAuth')
  try {
    try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if(-not $acquired) { throw 'Another switcher instance is updating a login. Wait for it to finish, then retry.' }
    return $mutex
  } catch { $mutex.Dispose(); throw }
}

function Assert-FileAuthStorage {
  $config=Join-Path (Get-RealCodexHome) 'config.toml'
  if(Test-Path -LiteralPath $config) {
    $text=[IO.File]::ReadAllText($config)
    if($text -match '(?m)^\s*cli_auth_credentials_store\s*=\s*["'']([^"'']+)["'']') {
      if($Matches[1] -ne 'file') { throw 'Shared switching currently supports file-based Codex logins only. Your credential-storage setting uses another method; the switcher has not changed that setting.' }
    }
  }
}

function Get-SharedHomeProcesses {
  # Fail closed if process discovery is unavailable. Child app servers and IDE
  # clients can retain a cached login, so checking only a window is insufficient.
  $processes=@(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe' OR Name = 'Codex.exe'" -ErrorAction Stop)
  return @($processes | Where-Object {
    -not $_.CommandLine -or $_.CommandLine -notmatch '--user-data-dir='
  })
}

function Test-RealHomeInstanceRunning { return (@(Get-SharedHomeProcesses).Count -gt 0) }

function Close-SharedDesktopApp {
  param($App)
  # Match the installed executable and the shared desktop root before ending
  # its process tree. Isolated desktop roots and independent clients are excluded.
  $desktop=@(Get-SharedHomeProcesses | Where-Object {
    $App.Exe -and $_.ExecutablePath -eq $App.Exe -and $_.CommandLine -and
      $_.CommandLine -notmatch '--(?:type|user-data-dir)(?:=|\s)'
  })
  $taskkill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
  foreach($entry in $desktop) {
    $process=Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
    if($process -and $process.Path -eq $App.Exe) {
      $kill=Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$process.Id,'/T','/F') -WindowStyle Hidden -Wait -PassThru
      if($kill.ExitCode -ne 0 -and -not $process.HasExited) {
        throw 'Windows could not fully stop ChatGPT. End the desktop app in Task Manager and retry.'
      }
    }
  }
  if($desktop.Count) {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while((Test-RealHomeInstanceRunning) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
  }
  if(Test-RealHomeInstanceRunning) {
    throw 'A ChatGPT or Codex process is still running. Close any independent Codex CLI or IDE sessions before switching.'
  }
}

function Wait-DesktopAppStart {
  param($App)
  $name=if($App.Exe){[IO.Path]::GetFileName($App.Exe)}else{'ChatGPT.exe'}
  $deadline=[DateTime]::UtcNow.AddSeconds(8)
  do {
    $procs=@(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $name.Replace("'","''")) -ErrorAction Stop)
    if(@($procs | Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and (-not $App.Exe -or $_.ExecutablePath -eq $App.Exe) }).Count -gt 0) { return }
    Start-Sleep -Milliseconds 200
  } while([DateTime]::UtcNow -lt $deadline)
  throw 'Windows accepted the launch request, but the desktop process did not start. The previous login will be restored when it is safe to do so.'
}

function Start-DefaultDesktopApp {
  param($App)
  $oldHome=$env:CODEX_HOME; $oldElectron=$env:CODEX_ELECTRON_USER_DATA_PATH
  try {
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_ELECTRON_USER_DATA_PATH -ErrorAction SilentlyContinue
    if($App.Kind -eq 'Store' -and $App.AppId) {
      Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\{0}!{1}' -f $App.PackageFamilyName,$App.AppId)
    } else { Start-Process -FilePath $App.Exe }
    Wait-DesktopAppStart $App
  } finally { $env:CODEX_HOME=$oldHome; $env:CODEX_ELECTRON_USER_DATA_PATH=$oldElectron }
}

function Save-CurrentAuthToAccount {
  param($Account)
  if(-not $Account -or $Account.mode -ne 'shared') { throw 'Choose a shared account to save this login.' }
  Assert-FileAuthStorage
  $mutex=Enter-AuthOperation
  try {
    $realAuth=Join-Path (Get-RealCodexHome) 'auth.json'
    if(-not (Get-AuthProfileInfo $realAuth)) { throw 'No readable file-based Codex login was found. Complete sign-in in the desktop app first.' }
    if($Account.id -ne $script:MainId -and -not (Test-Path -LiteralPath (Get-MainAuthStore))) {
      throw 'Save your original login as Main first, using Main account options. Then sign into the other account and save that login separately.'
    }
    $store=Get-SharedAuthStore $Account
    Copy-AuthFileAtomic $realAuth $store ($store+'.previous')
    Set-ActiveShared $Account.id
    Write-Log ('shared: saved login snapshot for '+$Account.id)
  } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Start-SharedAccount {
  param($Account,[bool]$RestartDesktop=$false)
  if(-not $Account) { throw 'The account was not found.' }
  $app=Get-ChatGptApp
  if(-not $app) { throw 'The supported desktop app was not found.' }
  $mutex=Enter-AuthOperation
  try {
    Assert-FileAuthStorage
    $store=Get-SharedAuthStore $Account
    $target=Get-AuthProfileInfo $store
    if(-not $target) { throw ('No login is saved for "{0}". Sign into that account in the desktop app, then use its Account options > Save current login. Main must be saved separately first.' -f $Account.display) }
    if($Account.id -ne $script:MainId -and -not (Get-AuthProfileInfo (Get-MainAuthStore))) {
      throw 'Main has no saved login yet. Save your original login using Main > Account options > Save current login as Main before switching.'
    }
    if($RestartDesktop -and (Test-RealHomeInstanceRunning)) {
      $currentProfile=Get-AuthProfileInfo (Join-Path (Get-RealCodexHome) 'auth.json')
      if($currentProfile -and $target.Identity -ceq $currentProfile.Identity) {
        Start-DefaultDesktopApp $app
        return
      }
      Close-SharedDesktopApp $app
    }
    if(Test-RealHomeInstanceRunning) {
      throw 'Fully quit the ChatGPT/Codex desktop app before switching saved logins. Close active Codex CLI or IDE clients too, because they can keep the old login cached. Your current login was left in place.'
    }
    $realAuth=Join-Path (Get-RealCodexHome) 'auth.json'
    $current=Get-AuthProfileInfo $realAuth
    $active=Get-ActiveShared
    # Capture refreshed credentials only when the identity still matches the
    # stored profile. A manual sign-in must never overwrite a different account.
    if($current -and $active) {
      $previous=Get-ManagedAccount $active
      if($previous -and $previous.mode -eq 'shared') {
        $previousStore=Get-SharedAuthStore $previous; $previousInfo=Get-AuthProfileInfo $previousStore
        if($previousInfo -and $previousInfo.Identity -ceq $current.Identity) {
          Copy-AuthFileAtomic $realAuth $previousStore ($previousStore+'.previous')
        }
      }
    }
    # Re-read after refresh capture: opening the same profile must use the latest
    # refreshed token, not a snapshot read before the capture.
    $backup=$realAuth+'.switcher-bak'; $hadAuth=Test-Path -LiteralPath $realAuth; $applied=$false
    try {
      Copy-AuthFileAtomic $store $realAuth $backup; $applied=$true
      Set-ActiveShared $Account.id
      Start-DefaultDesktopApp $app
      Write-Log ('shared: restored saved login and requested launch for '+$Account.id)
    } catch {
      if($applied -and -not (Test-RealHomeInstanceRunning)) {
        if($hadAuth -and (Test-Path -LiteralPath $backup)) { Copy-AuthFileAtomic $backup $realAuth }
        elseif(-not $hadAuth -and (Test-Path -LiteralPath $realAuth)) { [IO.File]::Delete($realAuth) }
        Set-ActiveShared $active
      }
      throw
    }
  } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}


function Get-PowerShellExe {
  return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# ------------------------------------------------------------------ ネイティブ（AppID / ジャンプリスト）

function Ensure-Native {
  if ('CGS.Native' -as [type]) { return $true }
  $code = @'
using System;
using System.Runtime.InteropServices;
namespace CGS {
  [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CShellLink { }
  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
  interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder f, int c, IntPtr fd, int fl);
    void GetIDList(out IntPtr ppidl); void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder n, int c);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string n);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder d, int c);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string d);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder a, int c);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string a);
    void GetHotkey(out short h); void SetHotkey(short h);
    void GetShowCmd(out int s); void SetShowCmd(int s);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder p, int c, out int i);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string p, int i);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string r, int dw);
    void Resolve(IntPtr hwnd, int fl); void SetPath([MarshalAs(UnmanagedType.LPWStr)] string f);
  }
  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
  interface IPersistFile {
    void GetClassID(out Guid c); [PreserveSig] int IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string f, int m);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.Bool)] bool r);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
  }
  [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
  interface IPropertyStore {
    void GetCount(out uint c); void GetAt(uint i, out PROPERTYKEY k);
    void GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    void SetValue(ref PROPERTYKEY k, ref PROPVARIANT v); void Commit();
  }
  [StructLayout(LayoutKind.Explicit, Size = 24)] struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p;
  }
  public static class Native {
    [DllImport("shell32.dll")] static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
    [DllImport("propsys.dll")] static extern int InitPropVariantFromString([MarshalAs(UnmanagedType.LPWStr)] string s, out PROPVARIANT pv);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);
    public static void SetProcessAppId(string id) { SetCurrentProcessExplicitAppUserModelID(id); }
    public static void SetShortcutAppId(string lnk, string id) {
      var sl = (IShellLinkW)new CShellLink();
      var pf = (IPersistFile)sl;
      pf.Load(lnk, 2); // STGM_READWRITE
      var ps = (IPropertyStore)sl;
      var key = new PROPERTYKEY(); key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); key.pid = 5;
      PROPVARIANT pv; InitPropVariantFromString(id, out pv);
      ps.SetValue(ref key, ref pv); ps.Commit();
      pf.Save(lnk, true); PropVariantClear(ref pv);
    }
  }
}
'@
  try { Add-Type -TypeDefinition $code -ErrorAction Stop; return $true }
  catch { Write-Log ("native load failed: {0}" -f $_.Exception.Message); return $false }
}

function Set-ProcessAppId {
  try { if (Ensure-Native) { [CGS.Native]::SetProcessAppId($script:AppId) } } catch { Write-Log "SetProcessAppId: $_" }
}

function Set-ShortcutAppId {
  param([string]$LnkPath)
  try { if (Ensure-Native) { [CGS.Native]::SetShortcutAppId($LnkPath, $script:AppId) } } catch { Write-Log "SetShortcutAppId: $_" }
}

# 右クリック（ジャンプリスト）にアカウント一覧を出す
function Set-JumpList {
  try {
    Set-ProcessAppId
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    $ps   = Get-PowerShellExe
    $icon = Get-AppIconPath
    $jl = New-Object System.Windows.Shell.JumpList
    $jl.ShowRecentCategory = $false
    $jl.ShowFrequentCategory = $false

    $rows = @()
    $rows += [pscustomobject]@{ id = $script:MainId; label = (Get-ManagedAccount $script:MainId).display }
    foreach ($a in (Get-Config).accounts) { $rows += [pscustomobject]@{ id = $a.id; label = $a.display } }

    foreach ($r in $rows) {
      $t = New-Object System.Windows.Shell.JumpTask
      $t.Title           = $r.label
      $t.CustomCategory  = 'Accounts'
      $t.ApplicationPath = $ps
      $t.Arguments       = ('-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Launch "{1}"' -f $script:ScriptPath, $r.id)
      if ($icon) { $t.IconResourcePath = $icon }
      $t.Description = ("Open ChatGPT with {0}" -f $r.label)
      $jl.JumpItems.Add($t)
    }

    # 一覧ウィンドウを開くタスク
    $open = New-Object System.Windows.Shell.JumpTask
    $open.Title = 'Open account switcher'
    $open.ApplicationPath = $ps
    $open.Arguments = ('-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:ScriptPath)
    if ($icon) { $open.IconResourcePath = $icon }
    $jl.JumpItems.Add($open)

    $jl.Apply()
    Write-Log ("jumplist applied: {0} items" -f $jl.JumpItems.Count)
  } catch { Write-Log ("jumplist skipped: {0}" -f $_.Exception.Message) }
}

function New-Shortcut {
  param([string]$LnkPath, [string]$Arguments, [string]$IconPath, [string]$Description)
  $dir = Split-Path -Parent $LnkPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $wsh = New-Object -ComObject WScript.Shell
  $lnk = $wsh.CreateShortcut($LnkPath)
  $lnk.TargetPath = Get-PowerShellExe
  $lnk.Arguments = ('-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $script:ScriptPath, $Arguments)
  $lnk.WorkingDirectory = Split-Path -Parent $script:ScriptPath
  $lnk.WindowStyle = 7   # 最小化で起動（コンソールのチラつき防止）
  if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { $lnk.IconLocation = "$IconPath,0" }
  if ($Description) { $lnk.Description = $Description }
  $lnk.Save()
  return $LnkPath
}

function Get-AppIconPath {
  param([switch]$SwitcherOnly)
  if($script:ScriptPath) {
    $folder=Split-Path -Parent $script:ScriptPath
    foreach($path in @((Join-Path $folder 'ChatGPT-Switcher.ico'),(Join-Path $folder 'assets\switcher.ico'))) {
      if(Test-Path -LiteralPath $path) { return $path }
    }
  }
  if($SwitcherOnly) { return $null }
  $app = Get-ChatGptApp
  if ($app -and $app.Exe) { return $app.Exe }
  return $null
}

function Get-AccountShortcutPath {
  param($Account)
  $desktop = [Environment]::GetFolderPath('Desktop')
  return (Join-Path $desktop ('ChatGPT - {0}.lnk' -f (Get-SafeName $Account.display)))
}

function New-AccountShortcut {
  param($Account)
  $lnk = Get-AccountShortcutPath $Account
  New-Shortcut -LnkPath $lnk -Arguments ('-Launch "{0}"' -f $Account.id) -IconPath (Get-AppIconPath) -Description ("Launch ChatGPT with {0}" -f $Account.display)
  Write-Log "shortcut created: $lnk"
  return $lnk
}

function New-PickerShortcuts {
  $icon = Get-AppIconPath
  $desktop = [Environment]::GetFolderPath('Desktop')
  $programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'ChatGPT Switcher'
  $made = @()
  $made += New-Shortcut -LnkPath (Join-Path $desktop 'ChatGPT Switcher.lnk') -Arguments '' -IconPath $icon -Description 'Choose an account and open ChatGPT'
  $made += New-Shortcut -LnkPath (Join-Path $programs 'ChatGPT Switcher.lnk') -Arguments '' -IconPath $icon -Description 'Choose an account and open ChatGPT'
  $made += New-Shortcut -LnkPath (Join-Path $programs 'ChatGPT Switcher (Tray).lnk') -Arguments '-Tray' -IconPath $icon -Description 'Switch accounts from the system tray'
  # ピン留めした切替アイコンを右クリック→アカウント一覧（ジャンプリスト）を出すための AppID を付与
  foreach ($m in $made) { Set-ShortcutAppId -LnkPath $m }
  Set-JumpList
  return $made
}

function Install-TrayAutoStart {
  $startup = [Environment]::GetFolderPath('Startup')
  return New-Shortcut -LnkPath (Join-Path $startup 'ChatGPT Switcher (Tray).lnk') -Arguments '-Tray' -IconPath (Get-AppIconPath) -Description 'ChatGPT Switcher (Tray)'
}

# ------------------------------------------------------------------ GUI: ピッカー

function New-AvatarImage {
  param([string]$Hex, [string]$Text, [int]$Size = 28)
  Ensure-Gui
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $color = [System.Drawing.ColorTranslator]::FromHtml('#252525')
  $brush = New-Object System.Drawing.SolidBrush($color)
  $g.FillEllipse($brush, 0, 0, $Size - 1, $Size - 1)
  $font = New-Object System.Drawing.Font('Segoe UI', [float]($Size * 0.45), [System.Drawing.FontStyle]::Bold)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
  $g.DrawString($Text, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
  $g.Dispose(); $brush.Dispose(); $font.Dispose(); $fmt.Dispose()
  return $bmp
}

# System tray: WinForms is retained only for native notification-area integration.

function Start-Tray {
  Ensure-Gui
  Set-JumpList
  $script:TrayExitPending=$false
  $ni = New-Object System.Windows.Forms.NotifyIcon
  $script:TrayIcon=$ni
  $iconPath = Get-AppIconPath
  $ni.Icon = [System.Drawing.SystemIcons]::Application
  if($iconPath) {
    try {
      if([IO.Path]::GetExtension($iconPath) -eq '.ico') { $ni.Icon=[Drawing.Icon]::new($iconPath,[Drawing.Size]::new(32,32)) }
      else { $ni.Icon=[Drawing.Icon]::ExtractAssociatedIcon($iconPath) }
    } catch {}
  }
  $ni.Text = 'ChatGPT Switcher'
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  $menu.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#E6E6E6')
  $menu.Renderer=New-Object System.Windows.Forms.ToolStripProfessionalRenderer ([CGS.TrayColors]::new())

  $menu.add_Opening({
    $m = $this
    foreach($old in @($m.Items)) { if($old.Image) { $old.Image.Dispose() }; $old.Dispose() }
    $m.Items.Clear()
    $running = Get-RunningAccountIds
    $active = Get-ActiveShared
    $head = $m.Items.Add($(if($script:LaunchBusy){'Opening account…'}else{'Open ChatGPT:'}))
    $head.Enabled = $false
    $mainItem = $m.Items.Add((Get-ManagedAccount $script:MainId).display + $(if ($running -contains $script:MainId) { '  (Running)' } else { '' }))
    $mainItem.Tag = $script:MainId
    $mainItem.Image = New-AvatarImage -Hex '#10A37F' -Text 'M' -Size 20
    $mainItem.add_Click({ try { Invoke-UiLaunch $this.Tag } catch { Show-Message $_.Exception.Message 'Error' 'Error' } })
    foreach ($a in (Get-Config).accounts) {
      $it = $m.Items.Add($a.display + $(if($a.mode -eq 'shared') { '  (Shared projects' + $(if($active -eq $a.id){'; selected'}else{''}) + ')' } elseif ($running -contains $a.id) { '  (Running)' } else { '' }))
      $it.Tag = $a.id
      $it.Image = New-AvatarImage -Hex $a.color -Text ([Globalization.StringInfo]::GetNextTextElement($a.display)) -Size 20
      $it.add_Click({ try { Invoke-UiLaunch $this.Tag } catch { Show-Message $_.Exception.Message 'Error' 'Error' } })
    }
    [void]$m.Items.Add('-')
    $add = $m.Items.Add('Add account')
    $add.add_Click({ Invoke-AddAccountFlow | Out-Null })
    $pick = $m.Items.Add('Open account switcher')
    $pick.add_Click({ Show-Picker })
    [void]$m.Items.Add('-')
    $quit = $m.Items.Add('Exit switcher')
    $quit.add_Click({ if($script:LaunchBusy) { $script:TrayExitPending=$true } else { [System.Windows.Forms.Application]::Exit() } })
    if($script:LaunchBusy) { foreach($item in $m.Items) { $item.Enabled=$false }; $quit.Enabled=$true }
  })

  $ni.ContextMenuStrip = $menu
  $ni.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Picker } })
  $ni.Visible = $true
  Write-Log 'tray started'
  try {
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
  } finally {
    $ni.Visible = $false
    $ni.Dispose()
    $menu.Dispose()
    $script:TrayIcon=$null
  }
}

# ------------------------------------------------------------------ 診断

function Show-Diagnose {
  Write-Host '=== ChatGPT Switcher diagnostics ===' -ForegroundColor Cyan
  Write-Host ("Version     : {0}" -f $script:AppVersion)
  Write-Host ("Script      : {0}" -f $script:ScriptPath)
  Write-Host ("Data folder : {0}" -f $script:Root)
  Write-Host ("PowerShell   : {0}" -f $PSVersionTable.PSVersion)
  Write-Host ("OS           : {0}" -f [Environment]::OSVersion.VersionString)
  Write-Host ''
  $app = Get-ChatGptApp
  if (-not $app) {
    Write-Host 'Desktop app: not found (Microsoft Store or standalone installation)' -ForegroundColor Red
  } else {
    Write-Host 'Desktop app:' -ForegroundColor Green
    Write-Host ("  Type      : {0}" -f $app.Kind)
    Write-Host ("  Version   : {0}" -f $app.Version)
    Write-Host ("  Location  : {0}" -f $app.InstallLocation)
    Write-Host ("  EXE       : {0}" -f $(if ($app.Exe) { $app.Exe } else { '(not found)' }))
    Write-Host ("  PFN       : {0}" -f $app.PackageFamilyName)
    Write-Host ("  AppId     : {0}" -f $app.AppId)
    if ($app.Exe) {
      try { $null = [System.IO.File]::OpenRead($app.Exe).Dispose(); Write-Host '  EXE access: OK' } catch { Write-Host "  EXE access: failed ($_)" -ForegroundColor Yellow }
    }
  }
  Write-Host ''
  Write-Host ("Default CODEX_HOME : {0}  (exists: {1})" -f (Join-Path $env:USERPROFILE '.codex'), (Test-Path (Join-Path $env:USERPROFILE '.codex')))
  $stock = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Roaming\Codex'
  Write-Host ("Default Electron data: {0}  (exists: {1})" -f $stock, (Test-Path $stock))
  Write-Host ''
  $running = Get-RunningAccountIds
  $cfg = Get-Config
  $active = Get-ActiveShared
  Write-Host ("Registered accounts: {0}   Selected shared account: {1}" -f $cfg.accounts.Count, $(if ($active) { $active } else { '(none)' })) -ForegroundColor Cyan
  Write-Host ("  [main] {0}{1}" -f $script:MainLabel, $(if ($running -contains $script:MainId) { '  (Running)' } else { '' }))
  foreach ($a in $cfg.accounts) {
    $p = Get-AccountPaths $a.id
    $m = if ($a.PSObject.Properties.Name -contains 'mode') { $a.mode } else { 'isolated' }
    Write-Host ("  [{0}] {1}  <{2}>{3}" -f $a.id, $a.display, $m, $(if ($running -contains $a.id) { '  (Running)' } else { '' }))
    if ($m -eq 'shared') {
      $store = Get-SharedAuthStore $a
      Write-Host ("      shared-auth: {0}  (saved: {1})" -f $store, (Test-Path $store))
    } else {
      Write-Host ("      electron: {0}" -f $p.Electron)
      Write-Host ("      codex   : {0}" -f $p.Codex)
    }
  }
  Write-Host ''
  Write-Host 'ChatGPT.exe processes:' -ForegroundColor Cyan
  try {
    Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" | Where-Object { $_.CommandLine -notmatch '--type=' } |
      ForEach-Object { Write-Host ("  PID {0}: {1}" -f $_.ProcessId, $_.CommandLine) }
  } catch { Write-Host "  (could not read processes: $_)" }
  Write-Host ''
  Write-Host ("Log: {0}" -f $script:LogPath)
}

# ------------------------------------------------------------------ エントリ

try {
  if ($Version) { Write-Host ("ChatGPT-Switcher {0}" -f $script:AppVersion); return }

  if ($Diagnose) { Show-Diagnose; return }

  if ($List) {
    $running = Get-RunningAccountIds
    $cfg = Get-Config
    Write-Host ("[{0}] {1}{2}" -f $script:MainId, $script:MainLabel, $(if ($running -contains $script:MainId) { '  (Running)' } else { '' }))
    foreach ($a in $cfg.accounts) {
      Write-Host ("[{0}] {1}{2}" -f $a.id, $a.display, $(if ($running -contains $a.id) { '  (Running)' } else { '' }))
    }
    return
  }

  if ($Add) {
    $acc = Add-Account -Display $Add -SkipShortcut:$NoShortcut -Shared:$Shared
    Write-Host ("Added: [{0}] {1}{2}" -f $acc.id, $acc.display, $(if ($acc.mode -eq 'shared') { ' (Shared projects)' } else { '' }))
    Write-Host ("Launch: ChatGPT-Switcher.ps1 -Launch {0}" -f $acc.id)
    if ($acc.mode -eq 'shared') {
      Write-Host "Shared projects: after signing in for the first time, save this login with:"
      Write-Host ("  ChatGPT-Switcher.ps1 -SaveAuth {0}" -f $acc.id)
    }
    return
  }

  if ($SaveAuth) {
    $acc = Get-ManagedAccount $SaveAuth
    if (-not $acc) { throw "Account `"$SaveAuth`" was not found." }
    if ($acc.mode -ne 'shared') { throw "`"$($acc.display)`" is not a shared-project account." }
    Save-CurrentAuthToAccount $acc
    Write-Host ('Saved the current login for "{0}".' -f $acc.display)
    return
  }

  if ($Remove) { Remove-Account $Remove; Write-Host "Removed: $Remove"; return }

  if ($Setup) {
    $made = New-PickerShortcuts
    $made | ForEach-Object { Write-Host "Created: $_" }
    $msg = "Shortcuts created:`n" + ($made -join "`n") + "`n`nTo pin the switcher, find ChatGPT Switcher in the Start menu and choose Pin to taskbar. Right-click its pinned icon to see your accounts."
    Write-Host $msg
    if (-not $NoShortcut) { Show-Message $msg }
    return
  }

  if ($AutoStartTray) { $lnk = Install-TrayAutoStart; Write-Host "Added to Windows startup: $lnk"; return }

  if ($Tray) { Start-Tray; return }

  if ($Launch) { Start-Account $Launch; return }

  Show-Picker
} catch {
  Write-Log ("ERROR: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
  if ($Diagnose -or $List -or $Add -or $Remove) {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
  }
  Show-Message ("Error: {0}`n`nDetails: {1}" -f $_.Exception.Message, $script:LogPath) 'ChatGPT Switcher' 'Error'
  exit 1
}
