Generate a README for this plugin
# Random Quote Plugin       
This plugin displays a random quote from a predefined library of quotes each time it is activated. The quotes are sourced from a `quotes.lua` file located within the plugin directory. If the `quotes.lua` file is missing, the plugin will fall back to a default list of quotes.
## Features
- Displays a random quote to the user.
- Reads quotes from a customizable `quotes.lua` file.
- Fallback to a default list of quotes if the custom file is not found.
## Installation
1. Download the `randomquote.koplugin` folder.
2. Place the folder in the `plugins` directory of your KOReader installation.
3. Restart KOReader to load the plugin.
## Usage
- Activate the plugin from the KOReader plugins menu to see a random quote.
## Customization
- To customize the quotes, create or edit the `quotes.lua` file in the `randomquote.koplugin` directory. The file should return a table of strings, each representing a quote.
## License
This plugin is released under the MIT License. See the LICENSE file for more details.   
## Credits
Developed by [Your Name].
