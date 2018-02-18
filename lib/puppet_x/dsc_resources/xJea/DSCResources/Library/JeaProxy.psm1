# Copyright � 2014, Microsoft Corporation. All rights reserved.
Import-Module $PSScriptRoot\..\Library\Helper.psm1
Import-Module $PSScriptRoot\..\Library\JeaDir.psm1

Add-Type @'
    namespace Jea
    {
    using System.Collections;
    using System.Collections.Generic;
    using System.Globalization;
    public class Parameter
    {
        public string ValidatePattern;
        public string ValidateSet;
        public string ParameterType;
        public string Mandatory;
    }
    public class Proxy
    {
        public string Module;
        public string Name;
        public Hashtable Parameter;
        public Proxy()
        {
            Parameter = new Hashtable(System.StringComparer.InvariantCultureIgnoreCase);
        }
    }
    }
'@




function ConvertTo-CSpec
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   Position=0)]
        $In
    )

    Begin
    {
    }
    Process
    {
        if ($In.Module -or $In.Name)
        {
            new-object psobject -Property @{
                Module          = $(if ($In.Module         ) {$In.module.Trim()         })
                Name            = $(if ($In.Name           ) {$In.Name.Trim()           }else {'*'})
                Parameter       = $(if ($In.Parameter      ) {$In.Parameter.Trim()      }else {'*'})
                ValidateSet     = $(if ($In.ValidateSet    ) {$In.ValidateSet.Trim()    })
                ValidatePattern = $(if ($In.ValidatePattern) {$In.ValidatePattern.Trim()})
                ParameterType   = $(if ($In.ParameterType  ) {$In.ParameterType.Trim()  })
                Mandatory       = $In.Mandatory
            }
        }
    }
    End
    {
    }
}

function Get-JeaProxy
{
param(
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateNotNull()]
        $Name,
        [Parameter(Mandatory=$true,Position=1)]
        [ValidateNotNull()]
        $Parameter
)
    #Names may specify specific commands or have wildcards to specify sets of commands
    if (!$CommandsToGenerate.$Name -and $Parameter)
    {
        $CommandsToGenerate.$Name = New-Object Jea.Proxy            
    }
    return $CommandsToGenerate.$Name
}

function Add-ParametersToProxy
{
param(
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateNotNull()]
        $Proxy,
        [Parameter(Mandatory=$true,Position=1)]
        [ValidateNotNull()]
        $CSpec,
        [Parameter(Mandatory=$true,Position=2)]
        [ValidateNotNull()]
        $CmdInfo
)

    if ($CSpec.Parameter -eq '*')
    {
        foreach ($ParameterName in $CmdInfo.Parameters.Keys)
        {
            $p = $proxy.parameter.($ParameterName)
            if (!$p)
            {
                $p = new-object Jea.Parameter
                $proxy.parameter.Add($ParameterName, $p)
            }              
        }  
    }
    else
    {
        $p = $proxy.parameter.$($CSpec.Parameter)
        if (!$p)
        {
            $p = new-object Jea.Parameter
            $proxy.parameter.Add($CSpec.Parameter.ToLower(), $p)
        }
        if ($CSpec.ValidateSet)
        {
            $p.ValidateSet =$CSpec.ValidateSet.Tolower()
        }            
        if ($CSpec.ValidatePattern)
        {
            $p.ValidatePattern = $CSpec.ValidatePattern
        }            
        if ($CSpec.ParameterType)
        {
            $p.ParameterType = $CSpec.ParameterType
        }            
        if ($CSpec.Mandatory)
        {
            $p.Mandatory = $CSpec.Mandatory
        }
    }
}

function ConvertTo-CommandsToGenerate
{
param(
        [Parameter(Mandatory=$true, 
                   ValueFromPipeline=$true,
                   Position=0)]
        [ValidateNotNull()]
        $CSpec
)
    Begin
    {
        $CommandsToGenerate = @{}
    }
    Process
    {
        $module = $CSpec.Module
        if ($module -match "\.dll$")
        {
            $module = ((split-path $module -Leaf) -split '.dll')[0]
        }
        foreach ($CmdInfo in Get-Command -Module $Module -Name $CSpec.Name -CommandType Function,Cmdlet)
        {
            $proxy = Get-JeaProxy -Name $CmdInfo.Name -Parameter $CSpec.Parameter
            Add-ParametersToProxy -Proxy $proxy -CSpec $CSpec -CmdInfo $cmdInfo
        }
    }
    End
    {
        return $CommandsToGenerate 
    }
}
function New-ToolKitPremable
{
    param
    (
        [Parameter(Mandatory)]
        [String]$Name,

        [String]
        $CommandSpecs,

        [System.String[]]
        $Applications
    )
        # Now we generate the File
@"
<#
This is a auto-generated module containing proxy cmdlets.
Generated At:     $(Get-date)
Generated On:     $(hostname)
Generated By:     $($env:UserDomain + '\' + $env:UserName)

#region OrginalCSVFile  
********************  START Original Source file  ***********************
$CommandSpecs
********************  END   Original Source file  ***********************
#endRegion

#>

$(
    $list = @()
    foreach ($a in $Applications) 
    {
        $list += """$a"""
    }
    if ($list.count)
    {
'$ExportedApplications = ' + ($list -join ',')
    }
    )
"@
}

# Some of these are dangerous and other get in the way of the runspace working
$forbiddenProxy = @(
    'Exit-Pssession','Format-Table','Format-List','Format-Custom','Format-Wide',
    'Get-Command','Get-Help','Get-Formatdata','Get-Member','Group-Object',
    'Import-Module','Measure-Object','New-Object','Out-Default','Select-Object',
    'TabExpansion2','Where-Object','Write-Debug','Write-Error','Write-Host',
    'Write-Output','Write-Verbose','Write-Warning'
)

function ConvertTo-ProxyFunctions
{
    [CmdletBinding()]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   Position=0)]
        $CmdName

    )

    Begin
    {
        # Proxy Modules are typically going to be used in constrained runspaces where best
        # practice will be to turn of ModuleAutoloading so the proxy needs to load whatever
        # modules it will proxy
        $modulesToImport = @{'Microsoft.PowerShell.Core'=1 }
        $exportCmdlet = @()
    }
    Process
    {
        $Cmd = Get-Command -Name $CmdName -CommandType Cmdlet,Function -ErrorAction Stop
        if (!$cmd)
        {
            Throw "No such Object [$CmdName :$CommandType]"
        }
        <#
        TODO:  Need to do some flavor of analsys of MANDATORY PARAMETERS in SETs
        #>
        foreach ($c in $cmd |where {$_.Name -notIn $forbiddenProxy})
        {
            if ($c.Module) {import-module -Name $c.module -ErrorAction Ignore -Verbose:0}
            if ($c.CommandType -eq 'function')
            {
                rename-item function:$($c.Name) $($c.Name + '-Original') 
                $c = Get-command -name ($cmdName + '-Original') -CommandType Function -ErrorAction Stop
            }
            $Parameter = $CommandsToGenerate.$CmdName.Parameter.Keys
            $MetaData = New-Object System.Management.Automation.CommandMetaData $c
            $metaData.Name = $CmdName

            foreach ($p in @($MetaData.Parameters.Keys))
            {
                $p = $p.Tolower()
                if ($p -notin $Parameter)
                {
                    $null = $MetaData.Parameters.Remove($p)
                }
                else
                {
                    $v = $CommandsToGenerate.$CmdName.Parameter.$p.ValidateSet
                    if ($v)
                    {
                        $MetaData.Parameters.$p.attributes.Add( $(New-Object System.Management.Automation.ValidateSetAttribute $($v -split ';')))                        
                    }
                    $v = $CommandsToGenerate.$CmdName.Parameter.$p.ValidatePattern
                    if ($v)
                    {
                        $MetaData.Parameters.$p.attributes.Add( $(New-Object System.Management.Automation.ValidatePatternAttribute $v))                        
                    }
                    $v = $CommandsToGenerate.$CmdName.Parameter.$p.ParameterType
                    if ($v)
                    {
                        $type = [System.AppDomain]::CurrentDomain.GetAssemblies().GetTypes() | where {$_.fullname -match $ParameterType}
                        if ($type)
                        {
                            $MetaData.Parameters.$p.ParameterType = $type[0].FullName
                        }
                    }
                    $v = $CommandsToGenerate.$CmdName.Parameter.$p.Mandatory
                    if ($v)
                    {
                        foreach($ps in $MetaData.Parameters.$p.Parametersets.Keys)
                        {
                            $MetaData.Parameters.$p.Parametersets.$PS.IsMandatory=$true
                        }
                    }
                }#end
            }#foreach

            if ($c.Module)
            {
                $RealModule = $c.module
                if (!$modulesToImport.$RealModule)
                {
                    $modulesToImport.$RealModule = 'Already imported'
@"
Import-Module $($RealModule) -Scope Global
"@
                }

            }
@"

#region $cmdname
$(
if ($c.CommandType -eq 'function')
{
"rename-item function:$cmdName $($cmdName+ '-Original')"
}
)
function $cmdName
{
"@
        [System.Management.Automation.ProxyCommand]::create($MetaData) 

@"
} # $cmdName
#endregion


"@
            $exportCmdlet += $CmdName
            
        } #foreach $cmd
        
    }
    End
    {
@"
Export-ModuleMember -Function $(($exportCmdlet | sort -Unique) -join ',')
#EOF
"@

    }
}

function Test-Schema
{
param(
    [Parameter(Mandatory)]
    $CSVs
)
    $allowed = 'Module','Name','Parameter','ValidateSet','ValidatePattern','ParameterType','Mandatory'
    $mismatch = $CSVs |Get-Member -MemberType Properties | where Name -notIn $Allowed
    if ($mismatch)
    {
        $errorMsg = "Incorrect CommandSpec schema:  $($Mismatch.Name -join ',')"
        Write-Verbose $errorMsg
        throw $errorMsg
    }
}
<#
.Synopsis
   Use a CSV-formated string to drive creation of a JeaProxy module
.DESCRIPTION
   JeaProxy modules provide fine grain control over what a user can invoke.
   It accomplishes this by manipulating the command parsing information and
   generating a proxy function.  This process is driven off a CommandSpecs which
   is a CSV formated string using the schema:
    Module,Name,Parameter,ValidateSet,ValidatePattern,ParameterType
    
    If only a name is specified, the cmdlet is surfaced in whole
    If a Name and a parameter are specified, then only those parameters will be 
        surfaced for that cmdlet.  Since it is a CSV format, only one parameter 
        can be specified on a line so we need to process all the lines and 
        consolidate the information before we create the proxies.
    If a Name, a parameter and a Validate is specified, we add a VALIDATESET 
        attribute with the values of the Validate field.  
        The values need to be seperated with a ';'.

    Applications can also be specified.  Applications are non-PowerShell 
    native executables (e.g. Ping.exe or IPconfig.exe)
.EXAMPLE
    Export-JeaProxy -Name GeneralAdmin -Applications "ping.exe","ipconfig.exe" -CommandSpecs @`
Module,Name,Parameter,ValidateSet,ValidatePattern,ParameterType
,Get-Process
,Stop-Process,Name,calc;notepad
,get-service
,Stop-Service,Name,,^SQL
`@
.OUTPUTS
    Two files are created in the ($env:ProgramFiles)\Jea\Toolkit directory
    1) $Name-Toolkit.psm1     # The proxy module
    2) $Name-CommandSpecs.csv # For diagnostics
.NOTES
   General notes
#>
function Export-JeaProxy
{
    param
    (
        [Parameter(Mandatory)]
        [String]$Name,

        [String]
        $CommandSpecs,

        [System.String[]]
        $Applications
    )

    $CommandSpecs >  (Join-Path (Get-JeaToolKitDir) "$($Name)-CommandSpecs.csv")
    Write-Verbose "New  [JeaDirectory.CSV]$($Name)-CommandSpecs.csv"

    $CSVs = $CommandsToGenerate = $CommandSpecs.ToLower() | ConvertFrom-Csv 
    Test-Schema $CSVs
    $CommandsToGenerate = $CSVs | ConvertTo-CSPec | ConvertTo-CommandsToGenerate

    $toolkit =  (Join-Path (Get-JeaToolKitDir) "$($Name)-ToolKit.psm1")
    New-ToolKitPremable @PSBoundParameters > $toolkit
    $CommandsToGenerate.Keys |Sort {($_ -split '-')[1]},{($_ -split '-')[0]} | ConvertTo-ProxyFunctions >> $toolkit
    Write-Verbose "New  [JeaDirectory.Module]$toolkit"
    
} #Export-JeaProxy

