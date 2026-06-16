<#
.SYNOPSIS
Outputs a window with the indicated wpf controls.

.DESCRIPTION
Creates a window object with 2-columns (labels and controls) or 1-column (using -HideLabels, with controls only).
Outputs the window without displaying it.
Note, the window doesn't build its own ok/cancel buttons so you are responsible for that.

This version includes thread-safe multithreading support with a single UI thread dispatcher for optimized updates.

.PARAMETER Contents
A scriptblock that outputs the controls you want in the window

.PARAMETER LabelMap
A hashtable with items of the form ControlName='Desired label'.  If the control is labeled it will use this text instead of the control name.

.PARAMETER Events
An array of hashtables of event handlers for controls in the dialog.  Each should have Name (control name), EventName, and Action.

.PARAMETER Title
The window title

.PARAMETER HideLabels
Use this switch if you want no labels at all (no column for them, even)

.PARAMETER Property
A hashtable of properties to set on the window

.PARAMETER Grid
Switch to say whether to show grid lines in all grids (for layout debugging)

.PARAMETER Display
Switch to say whether you want the window immediately shown (showdialog()) and if OK pressed
to output the "calculated output of the window".  Window with -Display works similarly to 
Dialog function but doesn't automatically add Ok and Cancel button.

.PARAMETER ThreadSafe
Switch to enable thread-safe operations. Allows background threads to queue updates via InvokeOnUI.

.EXAMPLE
Window {
    Textbox Name
    Button Personalize -name mike -action {
                                 $greeting.Content="Hello, $($name.Text)"}
    Label 'Hello, World' -name 'Greeting'
} -Display

.EXAMPLE
# Thread-safe usage from background threads
$w = Window {
    TextBox Message -name msg
    Button Update -name btn
} -ThreadSafe

$w.InvokeOnUI({
    $w.GetControlByName('msg').Text = 'Updated from thread'
})

.LINK
https://docs.microsoft.com/en-us/dotnet/api/system.windows.window
#>
function Window {
    [CmdletBinding()]
    param([scriptblock]$Contents,
        [hashtable]$LabelMap = @{},
        [hashtable[]]$Events,
        [string]$Title,
        [switch]$HideLabels, 
        [hashtable]$Property,
        [Switch]$Grid,
        [Switch]$Display,
        [Switch]$ThreadSafe
    )
    
    $script:Grid = $Grid.IsPresent
    $baseProperties = @{
        SizeToContent = 'WidthAndHeight'
        Margin        = 10
    }
    $w = New-WPFControl -type system.windows.window -properties $BaseProperties, $Property
    
    # Initialize thread-safe dispatcher and pending updates queue
    if ($ThreadSafe) {
        Add-Member -InputObject $w -MemberType NoteProperty -Name '_Dispatcher' -Value $null
        Add-Member -InputObject $w -MemberType NoteProperty -Name '_PendingUpdates' -Value (New-Object 'System.Collections.Generic.Queue[scriptblock]')
        Add-Member -InputObject $w -MemberType NoteProperty -Name '_UpdateLock' -Value (New-Object 'System.Object')
        Add-Member -InputObject $w -MemberType NoteProperty -Name '_IsUpdating' -Value $false
    }
    
    $w.Add_Loaded({
            $w.Activate()
            # Capture the UI dispatcher on the UI thread if this window has thread-safe support
            if ($w | Get-Member -Name '_Dispatcher' -ErrorAction SilentlyContinue) {
                $w._Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
                # Process any pending updates queued before dispatcher was ready
                if ($w._PendingUpdates.Count -gt 0) {
                    $w.FlushPendingUpdates()
                }
            }
        }.GetNewClosure())
    
    [array]$windowContent = & $Contents
    if ($windowContent.Count -gt 1) {
        $windowContent = StackPanel { $windowContent } -Orientation Vertical
    }
    $w.Content = $windowContent[0]
    $w | add-Member -MemberType ScriptMethod -Name GetControlByName -Value {
        Param($Name)
        $this.Content.GetControlByName($Name)
    }
    $w | add-member -MemberType ScriptMethod -Name Display -Value {
        # Ensure all pending updates are flushed before showing
        if ($this | Get-Member -Name FlushPendingUpdates) {
            $this.FlushPendingUpdates()
        }
        if ($this.ShowDialog()) {
            if ($this | Get-Member OverrideOutput) {
                $output = $This.OverrideOutput
            }
            else {
                $output = $this.GetWindowOutput()
                if ($output | get-member BuiltinDataEntryGrid) {
                    $output = $output.BuiltinDataEntryGrid
                }
                else {
                    $output = $output
                }
            }
            $Global:LastWPFBotOutput = $output
            $output
        }
    }
    $w | add-member -MemberType ScriptMethod -Name GetWindowOutput -value {
        if ($this | Get-Member -Name OverrideOutput -MemberType NoteProperty) {
            return $this.OverrideOutput
        }
        $this.Content.GetControlValue()
    }
    
    # Thread-safe method to invoke actions on the UI thread
    if ($ThreadSafe) {
        $w | add-member -MemberType ScriptMethod -Name InvokeOnUI -Value {
            param([scriptblock]$Action)
            if ($null -eq $this._Dispatcher) {
                # Dispatcher not yet initialized, queue the update
                [System.Threading.Monitor]::Enter($this._UpdateLock)
                try {
                    $this._PendingUpdates.Enqueue($Action)
                }
                finally {
                    [System.Threading.Monitor]::Exit($this._UpdateLock)
                }
            }
            else {
                # Dispatcher ready, invoke on UI thread
                if ($this._Dispatcher.CheckAccess()) {
                    # Already on UI thread
                    & $Action
                }
                else {
                    # On different thread, marshal to UI thread
                    $this._Dispatcher.Invoke($Action, [System.Windows.Threading.DispatcherPriority]::Normal) | Out-Null
                }
            }
        }
        
        # Process any pending updates that were queued before dispatcher was ready
        $w | add-member -MemberType ScriptMethod -Name FlushPendingUpdates -Value {
            if ($null -eq $this._Dispatcher) {
                return
            }
            [System.Threading.Monitor]::Enter($this._UpdateLock)
            try {
                while ($this._PendingUpdates.Count -gt 0) {
                    $update = $this._PendingUpdates.Dequeue()
                    $this._Dispatcher.Invoke($update, [System.Windows.Threading.DispatcherPriority]::Normal) | Out-Null
                }
            }
            finally {
                [System.Threading.Monitor]::Exit($this._UpdateLock)
            }
        }
        
        # Thread-safe method to update a specific control
        $w | add-member -MemberType ScriptMethod -Name UpdateControl -Value {
            param(
                [string]$ControlName,
                [string]$Property,
                $Value
            )
            $this.InvokeOnUI({
                    $control = $this.GetControlByName($ControlName)
                    if ($control) {
                        $control.$Property = $Value
                    }
                })
        }
        
        # Thread-safe batch update method for multiple properties
        $w | add-member -MemberType ScriptMethod -Name BatchUpdate -Value {
            param([hashtable]$Updates)
            $this.InvokeOnUI({
                    foreach ($controlName in $Updates.Keys) {
                        $control = $this.GetControlByName($controlName)
                        if ($control) {
                            $properties = $Updates[$controlName]
                            if ($properties -is [hashtable]) {
                                foreach ($prop in $properties.Keys) {
                                    $control.$prop = $properties[$prop]
                                }
                            }
                            else {
                                $control.Content = $properties
                            }
                        }
                    }
                })
        }
        
        # Run code on background thread to avoid blocking UI
        $w | add-member -MemberType ScriptMethod -Name InvokeAsync -Value {
            param(
                [scriptblock]$Action,
                [switch]$Wait,
                [int]$TimeoutMs = 0
            )
            $job = Start-Job -ScriptBlock $Action
            if ($Wait) {
                # Wait for completion while keeping UI responsive
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                while ($job.State -eq 'Running') {
                    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                        [Action] {},
                        [System.Windows.Threading.DispatcherPriority]::Background
                    )
                    Start-Sleep -Milliseconds 50
                    if ($TimeoutMs -gt 0 -and $stopwatch.ElapsedMilliseconds -gt $TimeoutMs) {
                        Stop-Job $job -ErrorAction SilentlyContinue
                        break
                    }
                }
                $stopwatch.Stop()
                $result = Receive-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -ErrorAction SilentlyContinue
                return $result
            }
            else {
                # Fire and forget - don't wait for completion
                return $job
            }
        }
    }

    $control = $null
    foreach ($item in $events) {
        if ($null -ne $item) {
            $control = $w.GetControlByName($item.Name)
            if ($control) {
                $control."Add_$($item.EventName)"($item.Action)
            }
        }
    }
    if ($title) {
        $w.Title = $title
    }
    
    # Ensure window is enabled and responsive
    $w.IsEnabled = $true
    
    if ($Display) {
        $w.Display()
    }
    else {
        $w
    }

}
