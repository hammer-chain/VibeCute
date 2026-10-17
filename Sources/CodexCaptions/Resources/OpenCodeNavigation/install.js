ObjC.import('Foundation');
function run(args) {
    const fm = $.NSFileManager.defaultManager;
    const source = args[0], root = args[1];
    const plugin = root + '/captions-navigation.mjs', config = root + '/tui.json';
    function exists(path) { return fm.fileExistsAtPath(path); }
    function read(path) {
        const value = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
        if (!value) throw new Error('无法读取文件：' + path);
        return ObjC.unwrap(value);
    }
    const body = read(source);
    // Parse before modifying anything. JSONC is loaded separately by OpenCode;
    // its comments and plugin list remain untouched in tui.jsonc.
    const original = exists(config) ? read(config) : undefined;
    const settings = original === undefined ? {} : JSON.parse(original);
    if (!settings || Array.isArray(settings) || typeof settings !== 'object') throw new Error('tui.json 必须是对象。');
    const nested = settings.tui && typeof settings.tui === 'object' && !Array.isArray(settings.tui) ? settings.tui : settings;
    if (nested.plugin !== undefined && !Array.isArray(nested.plugin)) throw new Error('tui.json 的 plugin 必须是数组。');
    const spec = ObjC.unwrap($.NSURL.fileURLWithPath(plugin).absoluteString);
    const list = nested.plugin || [];
    const added = !list.some(value => value === spec || (Array.isArray(value) && value[0] === spec));
    if (added) { list.push(spec); nested.plugin = list; }
    const edits = [];
    if (!exists(plugin) || read(plugin) !== body) edits.push([plugin, body]);
    // Preserve the exact user's JSON formatting on subsequent launches.
    if (added) edits.push([config, JSON.stringify(settings, null, 2) + '\n']);
    const stamp = Date.now().toString();
    edits.forEach(([path, text]) => {
        if (exists(path) && !fm.copyItemAtPathToPathError(path, path + '.' + stamp + '.bak', null))
            throw new Error('无法备份文件：' + path);
        const data = $(text).dataUsingEncoding($.NSUTF8StringEncoding);
        if (!data.writeToFileOptionsError(path, $.NSDataWritingAtomic, null)) throw new Error('无法保存文件：' + path);
    });
    return JSON.stringify({ status: edits.length ? 'installed' : 'up-to-date', plugin, config, requiresOpenCodeReload: !!edits.length });
}
