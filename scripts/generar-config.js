// Se ejecuta en Vercel al desplegar el panel docente.
// Genera public/config.js a partir de las variables de entorno de Vercel
// y copia index.html a public/, que es la carpeta que Vercel publica.
const fs = require('fs');
const path = require('path');

const url = process.env.SUPABASE_URL;
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;

if (!url || !publishableKey) {
  console.error(
    'ERROR: faltan las variables de entorno SUPABASE_URL y/o SUPABASE_PUBLISHABLE_KEY.\n' +
    'Agrégalas en Vercel -> Project -> Settings -> Environment Variables.'
  );
  process.exit(1);
}

if (publishableKey.startsWith('sb_secret_')) {
  console.error('ERROR: no uses una clave sb_secret_ en el panel web. Usa la sb_publishable_.');
  process.exit(1);
}

const raiz = path.join(__dirname, '..');
const salida = path.join(raiz, 'public');
fs.mkdirSync(salida, { recursive: true });

fs.copyFileSync(path.join(raiz, 'index.html'), path.join(salida, 'index.html'));
// Logo del panel (favicon y encabezado)
const carpetaLogo = path.join(salida, 'assets', 'branding');
fs.mkdirSync(carpetaLogo, { recursive: true });
fs.copyFileSync(
  path.join(raiz, 'assets', 'branding', 'logo.svg'),
  path.join(carpetaLogo, 'logo.svg')
);
fs.writeFileSync(
  path.join(salida, 'config.js'),
  `window.SUPABASE_CONFIG = ${JSON.stringify({ url, publishableKey }, null, 2)};\n`
);

console.log('Panel docente listo en public/ (index.html + config.js)');
