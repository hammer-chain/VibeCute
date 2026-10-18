# Rain-shelter smile patches

Small expression edits made with the built-in imagegen tool, using the existing frame-25 and frame-26 sprites as edit targets. Their parent character artwork retains the project's existing asset attribution.

`reach-mouth.png` and `lap-mouth.png` contain only a feathered mouth/skin region, normalized and registered by `patches.json`. `calibrate_rain_artwork.py` composites them after the original size/color calibration and restores the exact input alpha. No eye, hair, body, hand, basin or registration pixels outside these rectangles change. Frames 30/31 derive from the smiling frame 29 using the existing settle morph; frame 32 remains the canonical thinking pose.

The two full generated outputs and prompts stay in ignored `output/rain-shelter/smile-transition/`; they are not shipped. The patch files are authoring inputs and are not included in the app's resource manifests. Runtime uses the same 32 cached sprite slots and plays 01–22, then 25–32.
