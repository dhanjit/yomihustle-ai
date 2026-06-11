import os
import sys

# Make `import bridge` resolve to python/bridge.py regardless of pytest cwd.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
