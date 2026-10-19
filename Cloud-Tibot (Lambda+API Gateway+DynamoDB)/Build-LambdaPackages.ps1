# ============================================================================= 
# Lambda Deployment Package Builder
# Installs dependencies and packages Lambda functions properly
# =============================================================================

param(
    [switch]$CleanBuild,
    [switch]$Module1Only,
    [switch]$Module2Only,
    [switch]$Module3Only
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor $Color
    Write-Host $Message -ForegroundColor $Color
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor $Color
}

function Build-LambdaPackage {
    param(
        [string]$ModuleName,
        [string]$ModulePath
    )
    
    Write-Status "Building $ModuleName"
    
    $buildDir = Join-Path $ModulePath "build"
    $packageDir = Join-Path $buildDir "package"
    
    # Clean build directory if requested
    if ($CleanBuild -and (Test-Path $buildDir)) {
        Write-Host "  Cleaning existing build directory..." -ForegroundColor Yellow
        Remove-Item $buildDir -Recurse -Force
    }
    
    # Create build directories
    Write-Host "  Creating build directories..." -ForegroundColor White
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    
    # Install dependencies
    $requirementsFile = Join-Path $ModulePath "requirements.txt"
    if (Test-Path $requirementsFile) {
        Write-Host "  Installing dependencies from requirements.txt..." -ForegroundColor White
        
        try {
            python -m pip install -r $requirementsFile -t $packageDir --upgrade --quiet --no-cache-dir
            
            if ($LASTEXITCODE -ne 0) {
                throw "pip install failed with exit code $LASTEXITCODE"
            }
            
            Write-Host "  ✓ Dependencies installed successfully" -ForegroundColor Green
            
            # Remove unnecessary files to reduce package size
            Write-Host "  Cleaning up unnecessary files..." -ForegroundColor White
            $cleanupPatterns = @("*.dist-info", "__pycache__", "*.pyc", "tests", "test")
            foreach ($pattern in $cleanupPatterns) {
                Get-ChildItem -Path $packageDir -Directory -Filter $pattern -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path $packageDir -File -Filter $pattern -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            
        } catch {
            Write-Host "  ✗ Failed to install dependencies: $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Troubleshooting:" -ForegroundColor Yellow
            Write-Host "    1. Ensure Python 3.11+ is installed" -ForegroundColor Yellow
            Write-Host "    2. Ensure pip is up to date: python -m pip install --upgrade pip" -ForegroundColor Yellow
            Write-Host "    3. Check internet connectivity" -ForegroundColor Yellow
            throw
        }
    } else {
        Write-Host "  ⚠ No requirements.txt found" -ForegroundColor Yellow
    }
    
    # Copy Lambda function code (only .py files from source, not subdirectories)
    Write-Host "  Copying Lambda function code..." -ForegroundColor White
    $sourceFiles = Get-ChildItem $ModulePath -Filter "*.py" -File
    foreach ($file in $sourceFiles) {
        Copy-Item $file.FullName -Destination $packageDir -Force
        Write-Host "    - $($file.Name)" -ForegroundColor Gray
    }
    
    # Create ZIP archive
    $zipFile = Join-Path $buildDir "$ModuleName.zip"
    Write-Host "  Creating deployment package..." -ForegroundColor White
    
    if (Test-Path $zipFile) {
        Remove-Item $zipFile -Force
    }
    
    # Use .NET compression to avoid path issues
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($packageDir, $zipFile, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        Write-Host "  ✓ Package created successfully: $zipFile" -ForegroundColor Green
        
        # Show package size
        $size = (Get-Item $zipFile).Length / 1MB
        Write-Host "  Package size: $([math]::Round($size, 2)) MB" -ForegroundColor Cyan
    } catch {
        Write-Host "  ✗ Failed to create package: $_" -ForegroundColor Red
        throw
    }
    
    return $zipFile
}

function Update-TerraformForBuiltPackages {
    Write-Status "Updating Terraform Configuration"
    
    $lambdaTf = "lambda.tf"
    $content = Get-Content $lambdaTf -Raw
    
    # Note: We're not modifying Terraform - just informing the user
    Write-Host "  ⚠ After building packages, you have two options:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  OPTION 1: Manual Package Deployment (Recommended)" -ForegroundColor Cyan
    Write-Host "    Update Lambda functions manually with the built packages:" -ForegroundColor White
    Write-Host "    aws lambda update-function-code --function-name cloud-tibot_auto_remediator --zip-file fileb://src/module1/build/module1.zip" -ForegroundColor Gray
    Write-Host "    aws lambda update-function-code --function-name cloud-tibot_git_radar --zip-file fileb://src/module2/build/module2.zip" -ForegroundColor Gray
    Write-Host "    aws lambda update-function-code --function-name cloud-tibot_finops_sentinel --zip-file fileb://src/module3/build/module3.zip" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  OPTION 2: Terraform with Build Packages" -ForegroundColor Cyan
    Write-Host "    Modify lambda.tf to use the built packages in src/moduleX/build/ directory" -ForegroundColor White
    Write-Host "    Change: source_dir = src/moduleX" -ForegroundColor Gray
    Write-Host "    To:     source_file = src/moduleX/build/moduleX.zip" -ForegroundColor Gray
    Write-Host ""
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Host @"

╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║        PROJECT CORTEX - LAMBDA PACKAGE BUILDER                ║
║                                                               ║
║   Builds Lambda deployment packages with dependencies         ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Check Python installation
try {
    $pythonVersion = python --version 2>&1
    Write-Host "✓ Python installed: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ Python not found. Please install Python 3.11+" -ForegroundColor Red
    exit 1
}

# Check pip
try {
    $pipVersion = python -m pip --version 2>&1
    Write-Host "✓ pip installed: $pipVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ pip not found. Please install pip" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Build packages
$packages = @()

if (-not $Module2Only -and -not $Module3Only) {
    $packages += Build-LambdaPackage -ModuleName "module1" -ModulePath "src\module1"
}

if (-not $Module1Only -and -not $Module3Only) {
    $packages += Build-LambdaPackage -ModuleName "module2" -ModulePath "src\module2"
}

if (-not $Module1Only -and -not $Module2Only) {
    $packages += Build-LambdaPackage -ModuleName "module3" -ModulePath "src\module3"
}

# Summary
Write-Status "Build Complete!"

Write-Host ""
Write-Host "Built packages:" -ForegroundColor Cyan
foreach ($package in $packages) {
    Write-Host "  ✓ $package" -ForegroundColor Green
}

Write-Host ""
Update-TerraformForBuiltPackages

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Deploy updated Lambda functions (see options above)" -ForegroundColor White
Write-Host "  2. Test the functions: .\Test-AllPipelines.ps1" -ForegroundColor White
Write-Host "  3. Check CloudWatch logs for successful execution" -ForegroundColor White
Write-Host ""
