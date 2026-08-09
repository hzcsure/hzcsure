const puppeteer = require('puppeteer');
const fs = require('fs');

(async () => {
  console.log('🚀 开始抓取 MiSub 订阅链接...');

  const browser = await puppeteer.launch({
    headless: 'new',
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
    ]
  });

  const page = await browser.newPage();

  // 设置 User-Agent，伪装成普通浏览器
  await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

  // 注入剪贴板拦截
  await page.evaluateOnNewDocument(() => {
    window.__copiedLinks = [];
    const originalWriteText = navigator.clipboard.writeText;
    navigator.clipboard.writeText = function(text) {
      window.__copiedLinks.push(text);
      console.log('[拦截到复制]:', text);
      return originalWriteText.call(navigator.clipboard, text);
    };
  });

  // 打开页面
  console.log('📄 正在打开页面...');
  try {
    await page.goto('https://misub.schzyc.de5.net/', {
      waitUntil: 'networkidle2',
      timeout: 30000
    });
  } catch (e) {
    console.log('⚠️ 页面加载超时，继续尝试...');
    await new Promise(r => setTimeout(r, 5000));
  }

  await new Promise(r => setTimeout(r, 3000));

  // 方法：从 Pinia Store 获取数据（最可靠）
  console.log('🔍 正在从前端 Store 获取订阅组数据...');
  let profiles = [];
  
  try {
    profiles = await page.evaluate(() => {
      const app = document.querySelector('#app').__vue_app__;
      if (!app) return [];
      
      const pinia = app.config.globalProperties.$pinia;
      if (!pinia) return [];
      
      const result = [];
      for (const [name, store] of pinia._s) {
        for (const key of Object.keys(store.$state)) {
          const value = store.$state[key];
          if (Array.isArray(value) && value.length > 0) {
            if (value[0]?.customId && value[0]?.name) {
              return value.map(item => ({
                name: item.name,
                customId: item.customId,
                id: item.id,
                description: item.description || '',
                subscriptionCount: item.subscriptionCount || 0,
                manualNodeCount: item.manualNodeCount || 0
              }));
            }
          }
        }
      }
      return result;
    });
  } catch (e) {
    console.log('⚠️ Store 获取失败:', e.message);
  }

  // 如果 Store 方式失败，尝试从 API 获取
  if (profiles.length === 0) {
    console.log('🔄 尝试通过公开 API 获取...');
    try {
      const response = await page.evaluate(async () => {
        const res = await fetch('/api/public/profiles');
        return await res.json();
      });
      
      if (response.success && response.data) {
        profiles = response.data;
        console.log('✅ 通过 API 获取成功');
      }
    } catch (e) {
      console.log('⚠️ API 获取失败:', e.message);
    }
  }

  // 获取 profileToken
  let profileToken = 'profiles';
  try {
    const configData = await page.evaluate(async () => {
      const res = await fetch('/api/public/profiles');
      return await res.json();
    });
    if (configData.config?.profileToken) {
      profileToken = configData.config.profileToken;
    }
  } catch (e) {}

  console.log(`\n📊 找到 ${profiles.length} 个订阅组\n`);

  // 构造订阅链接
  const baseUrl = 'https://misub.schzyc.de5.net';
  
  const results = profiles.map(p => ({
    name: p.name,
    description: p.description || '',
    customId: p.customId,
    subscriptionUrl: `${baseUrl}/sub/${profileToken}/${p.customId}`,
    subscriptionCount: p.subscriptionCount || 0,
    manualNodeCount: p.manualNodeCount || 0
  }));

  // 打印结果
  results.forEach((r, i) => {
    console.log(`${i + 1}. ${r.name}`);
    console.log(`   链接: ${r.subscriptionUrl}`);
    console.log(`   描述: ${r.description || '无'}`);
    console.log(`   订阅数: ${r.subscriptionCount}，手动节点: ${r.manualNodeCount}`);
    console.log();
  });

  // 保存结果到 JSON 文件
  const output = {
    crawlTime: new Date().toISOString(),
    site: 'https://misub.schzyc.de5.net/',
    profileToken: profileToken,
    count: results.length,
    profiles: results
  };

  fs.writeFileSync('result.json', JSON.stringify(output, null, 2));
  console.log('💾 结果已保存到 result.json');

  // 也保存一个 Markdown 格式，方便阅读
  let md = `# MiSub 订阅链接\n\n`;
  md += `> 抓取时间: ${new Date().toLocaleString('zh-CN')}\n\n`;
  md += `## 订阅列表\n\n`;
  md += `| 订阅组 | 描述 | 订阅数 | 手动节点 | 订阅链接 |\n`;
  md += `|--------|------|--------|----------|----------|\n`;
  
  results.forEach(r => {
    md += `| ${r.name} | ${r.description || '-'} | ${r.subscriptionCount} | ${r.manualNodeCount} | [链接](${r.subscriptionUrl}) |\n`;
  });
  
  fs.writeFileSync('README-result.md', md);
  console.log('📝 Markdown 报告已保存到 README-result.md');

  await browser.close();
  console.log('\n🎉 抓取完成！');
})();
