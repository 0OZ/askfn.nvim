# Record with: vhs demo/demo.tape   (from the plugin root; needs vhs and lua-language-server)
Output assets/demo.gif
Output assets/demo.mp4

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 640
Set Padding 20
Set Framerate 30
Set TypingSpeed 55ms
Set WindowBar Colorful
Set BorderRadius 8
Set Theme "Catppuccin Mocha"

Hide
Type "nvim -u demo/init.lua demo/sample.lua" Enter
Sleep 2500ms
Show

# the text object: whole function, signature included
Type "5G"
Sleep 600ms
Type "vaf"
Sleep 1500ms
Escape

# ask
Type " aq"
Sleep 800ms
Type "why is there jitter?"
Sleep 400ms
Enter
Sleep 1200ms
Sleep 3200ms
Sleep 2500ms

# follow up in the same session
Enter
Sleep 600ms
Type "how do I test it?"
Sleep 400ms
Enter
Sleep 6500ms

# copy the code block, close
Type "gY"
Sleep 1500ms
Type "q"
Sleep 1200ms
