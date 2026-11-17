To install all you need is Xcode command line tools install by running this command
xcode-select --install
Now just extract the file called build in the same folder and run it 
If it says something about being not verified run this command in terminal
xattr -cr /path/to/app
Replace the "path to app" to the file path to the build.app by dragging the app in there after typing 
"xattr -cr "