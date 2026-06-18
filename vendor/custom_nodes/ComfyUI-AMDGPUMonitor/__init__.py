import os
import sys
import json
import time
import subprocess
import threading
import asyncio
from server import PromptServer

# Global variable to store GPU stats
gpu_stats = {
    "gpu_utilization": 0,
    "vram_used": 0,
    "vram_total": 0,
    "vram_used_percent": 0,
    "gtt_used": 0,                # NEW
    "gtt_total": 0,               # NEW
    "gtt_used_percent": 0,        # NEW
    "gpu_temperature": 0,
    "gpu_name": "",               # NEW
    "last_update": 0
}

# Monitor thread control
monitor_thread = None
thread_control = threading.Event()
monitor_update_interval = 1  # seconds

def _to_int(val, default=0):
    try:
        return int(float(str(val).replace('%', '').strip()))
    except:
        return default

def find_rocm_smi():
    """Find the rocm-smi or amd-smi executable"""
    rocm_paths = [
        "/opt/venv/bin/rocm-smi",
        "/opt/rocm/bin/rocm-smi",
        "/usr/bin/rocm-smi",
        "/usr/local/bin/rocm-smi",
        "/opt/amdgpu-pro/bin/amd-smi",
        "/usr/bin/amd-smi",
    ]
    
    for path in rocm_paths:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    
    # Try to find it in PATH
    try:
        result = subprocess.run(["which", "rocm-smi"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass
        
    try:
        result = subprocess.run(["which", "amd-smi"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass
    
    return None

def run_rocm_smi_command(rocm_smi_path, *args):
    if not rocm_smi_path:
        return {}
    cmd = [rocm_smi_path] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        # JSON-first: some builds return warnings + valid JSON
        if '--json' in args:
            try:
                return json.loads(r.stdout or "{}")
            except json.JSONDecodeError:
                return {}
        if r.returncode == 0:
            return r.stdout
        return {}
    except Exception:
        return {}


def get_gpu_info(rocm_smi_path):
    """Get current GPU information"""
    global gpu_stats
    
    # Get GPU utilization
    try:
        info = run_rocm_smi_command(rocm_smi_path, '--showuse', '--json')
        if isinstance(info, dict) and 'card0' in info:
            card_info = info['card0']  # Use first GPU
            if 'GPU use (%)' in card_info:
                gpu_use = card_info['GPU use (%)']
                if isinstance(gpu_use, str):
                    gpu_use = gpu_use.replace('%', '')
                gpu_stats["gpu_utilization"] = int(float(gpu_use))
    except:
        pass
    
    # Get VRAM information
    try:
        info = run_rocm_smi_command(rocm_smi_path, '--showmeminfo', 'vram', '--json')
        if isinstance(info, dict) and 'card0' in info:
            card_info = info['card0']  # Use first GPU
            
            # Parse the B (bytes) format ROCm 5.x/6.x uses
            if 'VRAM Total Memory (B)' in card_info and 'VRAM Total Used Memory (B)' in card_info:
                vram_total_bytes = int(card_info['VRAM Total Memory (B)'])
                vram_used_bytes = int(card_info['VRAM Total Used Memory (B)'])
                
                # Convert to MB for display
                vram_total = vram_total_bytes / (1024 * 1024)
                vram_used = vram_used_bytes / (1024 * 1024)
                
                gpu_stats["vram_total"] = int(vram_total)
                gpu_stats["vram_used"] = int(vram_used)
                gpu_stats["vram_used_percent"] = int((vram_used / vram_total) * 100)
    except:
        pass

    # Get temperature
    try:
        info = run_rocm_smi_command(rocm_smi_path, '--showtemp', '--json')
        if isinstance(info, dict) and 'card0' in info:
            card_info = info['card0']  # Use first GPU
            
            # Try different temperature sensors, starting with edge
            if 'Temperature (Sensor edge) (C)' in card_info:
                temp_str = card_info['Temperature (Sensor edge) (C)']
                if isinstance(temp_str, str):
                    temp_str = temp_str.replace('°C', '').strip()
                gpu_stats["gpu_temperature"] = int(float(temp_str))
            elif 'Temperature (Sensor junction) (C)' in card_info:
                temp_str = card_info['Temperature (Sensor junction) (C)']
                if isinstance(temp_str, str):
                    temp_str = temp_str.replace('°C', '').strip()
                gpu_stats["gpu_temperature"] = int(float(temp_str))
    except:
        pass

    # GTT (unified) memory — exact keys from your machine
    try:
        info = run_rocm_smi_command(rocm_smi_path, '--showmeminfo', 'gtt', '--json')
        if isinstance(info, dict) and 'card0' in info:
            ci = info['card0']
            total_b = ci.get('GTT Total Memory (B)')
            used_b  = ci.get('GTT Total Used Memory (B)')
            if total_b and used_b:
                gtt_total_mb = int(str(total_b)) // (1024 * 1024)
                gtt_used_mb  = int(str(used_b))  // (1024 * 1024)
                gpu_stats["gtt_total"] = gtt_total_mb
                gpu_stats["gtt_used"] = gtt_used_mb
                gpu_stats["gtt_used_percent"] = int((gtt_used_mb / gtt_total_mb) * 100) if gtt_total_mb else 0
            else:
                print("GTT keys missing; got:", list(ci.keys()))
    except Exception as e:
        print("GTT parse error:", e)

        # GPU name from product info
    try:
        info = run_rocm_smi_command(rocm_smi_path, '--showproductname', '--json')
        if isinstance(info, dict) and 'card0' in info:
            ci = info['card0']
            name = None
            # Your output includes Card Series and GFX Version
            if ci.get('Card Series') and str(ci['Card Series']).strip() not in ('N/A', ''):
                name = str(ci['Card Series']).strip()
            elif ci.get('GFX Version'):
                name = str(ci['GFX Version']).strip()
            elif ci.get('Card Model'):
                name = f"Device {ci['Card Model']}"
            gpu_stats["gpu_name"] = name or gpu_stats.get("gpu_name", "")
    except Exception:
        pass
    
    gpu_stats["last_update"] = time.time()
    return gpu_stats
    
def send_monitor_update():
    data = {
        'device_type': 'rocm',
        'gpus': [{
            'name': gpu_stats.get('gpu_name', ''),
            'gpu_utilization': gpu_stats['gpu_utilization'],
            'gpu_temperature': gpu_stats['gpu_temperature'],
            'vram_total': gpu_stats['vram_total'],
            'vram_used': gpu_stats['vram_used'],
            'vram_used_percent': gpu_stats['vram_used_percent'],
            'gtt_total': gpu_stats.get('gtt_total', 0),
            'gtt_used': gpu_stats.get('gtt_used', 0),
            'gtt_used_percent': gpu_stats.get('gtt_used_percent', 0),
        }]
    }
    try:
        PromptServer.instance.send_sync('amd_gpu_monitor', data)
    except:
        pass

def monitor_thread_function():
    """Thread function to continuously monitor GPU stats"""
    global monitor_update_interval
    
    rocm_smi_path = find_rocm_smi()
    if not rocm_smi_path:
        print("ERROR: Could not find rocm-smi or amd-smi executable")
        return
    
    print(f"Using AMD SMI tool: {rocm_smi_path}")
    
    while not thread_control.is_set():
        try:
            get_gpu_info(rocm_smi_path)
            # Send update to UI
            send_monitor_update()
        except:
            pass
        
        # Sleep for the update interval
        time.sleep(monitor_update_interval)

def start_monitor_thread():
    """Start the GPU monitoring thread"""
    global monitor_thread, thread_control
    
    if monitor_thread is not None and monitor_thread.is_alive():
        # Already running
        return
    
    # Clear the control event and start new thread
    thread_control.clear()
    monitor_thread = threading.Thread(target=monitor_thread_function)
    monitor_thread.daemon = True
    monitor_thread.start()
    print("AMD GPU Monitor thread started")

def stop_monitor_thread():
    """Stop the GPU monitoring thread"""
    global monitor_thread, thread_control
    
    if monitor_thread is None or not monitor_thread.is_alive():
        # Not running
        return
    
    # Set control event to stop thread
    thread_control.set()
    monitor_thread.join(timeout=5)
    print("AMD GPU Monitor thread stopped")

# Start the monitor thread when this module is loaded
start_monitor_thread()

# Define our nodes (not really used, but required for ComfyUI to load the extension)
class AMDGPUMonitor:
    """
    A placeholder node for ComfyUI. The actual monitoring is done via a separate thread.
    """
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "update_interval": ("FLOAT", {"default": 1.0, "min": 0.1, "max": 10.0, "step": 0.1}),
            },
        }
    
    RETURN_TYPES = ("STRING",)
    FUNCTION = "monitor_gpu"
    CATEGORY = "AMD GPU"
    
    def monitor_gpu(self, update_interval):
        """Update interval can be changed via input"""
        global monitor_update_interval
        monitor_update_interval = update_interval
        
        # Return current stats as a string for debugging
        stats = (
            f"GPU: {gpu_stats['gpu_utilization']}% | "
            f"VRAM: {gpu_stats['vram_used']}MB/{gpu_stats['vram_total']}MB ({gpu_stats['vram_used_percent']}%) | "
            f"GTT: {gpu_stats['gtt_used']}MB/{gpu_stats['gtt_total']}MB ({gpu_stats['gtt_used_percent']}%) | "  # NEW
            f"Temp: {gpu_stats['gpu_temperature']}°C | "
            f"Name: {gpu_stats.get('gpu_name','')}"                                                             # NEW
        )
        return (stats,)

# Register our node when this script is imported
NODE_CLASS_MAPPINGS = {
    "AMDGPUMonitor": AMDGPUMonitor,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "AMDGPUMonitor": "AMD GPU Monitor",
}

# This cleanup will be called when ComfyUI is shutting down
def cleanup():
    stop_monitor_thread()

# Web directory setup for ComfyUI to find our JS files
WEB_DIRECTORY = os.path.join(os.path.dirname(os.path.realpath(__file__)), "web")
print(f"AMD GPU Monitor: Web directory set to {WEB_DIRECTORY}")
