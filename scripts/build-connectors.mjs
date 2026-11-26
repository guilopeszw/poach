import {build} from 'esbuild';
import {mkdir, writeFile, copyFile, mkdtemp, rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {join, resolve, dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const out = join(root,'outputs/connectors');
const market = join(out,'marketplace');
const plugin = join(market,'plugins/poach');
const appServerPath = process.argv[2];
const entry = appServerPath ?? join(plugin,'server.mjs');
const stage = await mkdtemp(join(tmpdir(),'poach-extension-'));
const json = async (path, data) => {
  await mkdir(dirname(path),{recursive:true});
  await writeFile(path, JSON.stringify(data,null,2)+'\n');
};
const metadata = {name:'poach', version:'1.0.1', description:'Read the screen capture, keyframes, and timestamped notes you share from Poach.'};
try {
  await mkdir(plugin,{recursive:true});
  await build({
    entryPoints: [resolve(root, 'packages/mcp-server/dist/index.js')],
    outfile: entry,
    bundle: true,
    platform: 'node',
    format: 'esm',
    banner: {js: "import {createRequire} from 'node:module'; const require=createRequire(import.meta.url);"},
    target: 'node20',
    plugins: appServerPath ? [{
      name: 'packaged-core',
      setup(build) {
        build.onResolve({filter: /^@poach\/core$/}, () => ({
          path: './core/dist/index.js',
          external: true,
        }));
      },
    }] : [],
  });
  const launcher = join(root, 'scripts/launch-connector.sh');
  await json(join(market,'.agents/plugins/marketplace.json'),{name:'poach-local',plugins:[{name:'poach',source:{source:'local',path:'./plugins/poach'},policy:{installation:'AVAILABLE',authentication:'ON_INSTALL'},category:'Productivity'}]});
  const logo = join(root, 'apps/macos/Assets/PoachConnectorIcon.png');
  await mkdir(join(plugin, 'assets'), {recursive:true});
  await copyFile(logo, join(plugin, 'assets/poach.png'));
  await copyFile(logo, join(stage, 'icon.png'));
  await json(join(plugin,'.codex-plugin/plugin.json'),{
    ...metadata, author:{name:'Guilherme Lopes',url:'https://github.com/guilopeszw'}, mcpServers:'./.mcp.json',
    interface:{displayName:'Poach', logo:'./assets/poach.png', composerIcon:'./assets/poach.png'}
  });
  // The installer resolves these paths on the destination Mac.
  await json(join(plugin,'.mcp.json'),{mcpServers:{poach:{command:"/bin/bash",args:["launch-connector.sh"]}}});
  await copyFile(join(root,'scripts/install-codex-connector.sh'),join(out,'Install Codex.command'));
  await copyFile(launcher,join(plugin,'launch-connector.sh'));
  await copyFile(launcher,join(stage,'launch-connector.sh'));
  await json(join(stage,'manifest.json'),{manifest_version:'0.3',...metadata,display_name:'Poach',icon:'icon.png',author:{name:'Guilherme Lopes',url:'https://github.com/guilopeszw'},server:{type:'binary',entry_point:'launch-connector.sh',mcp_config:{command:'/bin/bash',args:['${__dirname}/launch-connector.sh']}},compatibility:{platforms:['darwin']}});
  const archive=join(out,'Poach.mcpb');
  await rm(archive,{force:true});
  execFileSync('zip',['-q',archive,'manifest.json','launch-connector.sh','icon.png'],{cwd:stage});
  console.log(market+'\n'+archive);
} finally { await rm(stage,{recursive:true,force:true}); }
