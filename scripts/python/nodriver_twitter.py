#!/usr/bin/env python3

import asyncio
import json
import argparse
import sys
import os

try:
    import nodriver as uc
except ImportError:
    print(json.dumps({"error": "nodriver not installed"}), file=sys.stderr)
    sys.exit(1)

import browser_binary

# Esperas adaptativas para a timeline do X.
TWEET_WAIT_TIMEOUT = 12.0
TWEET_WAIT_POLL = 0.25
# Após cada scroll: aguarda aumento do conjunto de IDs ou mudança de altura.
SCROLL_SETTLE_TIMEOUT = 4.0
SCROLL_SETTLE_POLL = 0.15
# Teto absoluto de segurança, independente da hipótese de 5 posts por scroll.
MAX_SCROLL_ITERATIONS = 30
# Número de iterações consecutivas sem progresso para encerrar a coleta.
STAGNATION_THRESHOLD = 3


async def wait_for_tweets(page, timeout=TWEET_WAIT_TIMEOUT):
    """
    Polling de `article[data-testid="tweet"]`; timeout explícito.
    Retorna a contagem quando encontra ao menos um tweet, senão 0.
    """
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        count = await page.evaluate(
            "document.querySelectorAll('article[data-testid=\"tweet\"]').length"
        )
        if count and count > 0:
            return count
        try:
            await asyncio.sleep(TWEET_WAIT_POLL)
        except asyncio.CancelledError:
            break
    return 0


async def wait_for_scroll_progress(page, seen_ids, prev_height, timeout=SCROLL_SETTLE_TIMEOUT):
    """
    Após um scroll, aguarda aumento do conjunto de IDs ou mudança de altura.
    Retorna (new_ids_set, new_height, changed_bool).
    """
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        try:
            current_height = await page.evaluate("document.body.scrollHeight")
        except Exception:
            current_height = prev_height
        raw_ids = await _collect_tweet_ids(page)
        new_ids = set(raw_ids) if isinstance(raw_ids, (list, set)) else set()
        new_seen_ids = seen_ids | new_ids
        changed = bool(new_ids - seen_ids) or current_height != prev_height
        if changed:
            return new_seen_ids, list(new_ids), current_height, True
        try:
            await asyncio.sleep(SCROLL_SETTLE_POLL)
        except asyncio.CancelledError:
            break
    return seen_ids, [], prev_height, False


async def _collect_tweet_ids(page):
    """Coleta os IDs de permalink de todos os artigos de tweet visíveis."""
    result = await page.evaluate(
        """
        (function() {
            try {
                var articles = document.querySelectorAll('article[data-testid="tweet"]');
                var ids = [];
                articles.forEach(function(article) {
                    try {
                        var timeEl = article.querySelector('time');
                        var linkEl = timeEl ? timeEl.closest('a') : null;
                        var permalink = linkEl ? linkEl.getAttribute('href') : null;
                        var postId = permalink ? permalink.split('/').pop() : null;
                        if (postId) ids.push(postId);
                    } catch(e) {}
                });
                return JSON.stringify(ids);
            } catch(e) {
                return JSON.stringify({error: e.message});
            }
        })()
        """
    )
    try:
        parsed = json.loads(result)
        if isinstance(parsed, dict) and parsed.get("error"):
            return []
        if isinstance(parsed, list):
            return parsed
    except Exception:
        pass
    return []


async def scrape_profile(username, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))
    try:
        page = await browser.get(f"https://x.com/{username}")

        ready_timeout = float(os.environ.get("TWITTER_READY_TIMEOUT", TWEET_WAIT_TIMEOUT))
        await wait_for_tweets(page, timeout=ready_timeout)

        result = await page.evaluate(
            """
            (function() {
                try {
                    var state = {};
                    var scripts = document.querySelectorAll('script[type="application/json"]');
                    for (var i = 0; i < scripts.length; i++) {
                        try {
                            var data = JSON.parse(scripts[i].textContent);
                            if (data && typeof data === 'object') {
                                var jsonStr = JSON.stringify(data);
                                if (jsonStr.includes('legacy') && jsonStr.includes('followers_count')) {
                                    var findUser = function(obj) {
                                        if (!obj || typeof obj !== 'object') return null;
                                        if (obj.screen_name && obj.followers_count !== undefined) return obj;
                                        for (var key in obj) {
                                            var found = findUser(obj[key]);
                                            if (found) return found;
                                        }
                                        return null;
                                    };
                                    var user = findUser(data);
                                    if (user) {
                                        return JSON.stringify({
                                            user_id: user.id_str || user.id,
                                            username: user.screen_name,
                                            display_name: user.name,
                                            bio: user.description,
                                            followers_count: user.followers_count,
                                            following_count: user.friends_count,
                                            posts_count: user.statuses_count,
                                            is_private: user.protected,
                                            is_verified: user.verified,
                                            profile_image_url: user.profile_image_url_https,
                                            banner_url: user.profile_banner_url,
                                            location: user.location
                                        });
                                    }
                                }
                            }
                        } catch(e) {}
                    }
                    var metaDesc = document.querySelector('meta[name="description"]');
                    var metaTitle = document.querySelector('meta[property="og:title"]');
                    if (metaDesc) {
                        return JSON.stringify({
                            username: %(username)s,
                            bio: metaDesc.getAttribute('content'),
                            display_name: metaTitle ? metaTitle.getAttribute('content') : null,
                            fallback: true
                        });
                    }
                    return null;
                } catch(e) {
                    return JSON.stringify({error: e.message});
                }
            })()
            """ % {"username": json.dumps(username)}
        )

        if result:
            return json.loads(result)
        return None
    finally:
        await browser.stop()


async def scrape_posts(username, limit=20, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))
    try:
        page = await browser.get(f"https://x.com/{username}")

        # Substitui a espera inicial fixa: polling de artigos de tweet.
        # Engolir silenciosamente a exceção de wait_for_tweets mascara falhas
        # reais de evaluate (ex.: conexão perdida). Loga em stderr para
        # observabilidade, mas não interrompe o scrape — o conteúdo
        # disponível ainda é coletado abaixo por _extract_posts.
        try:
            await wait_for_tweets(page)
        except Exception as e:
            print(json.dumps({"warning": "wait_for_tweets falhou: %s" % e}), file=sys.stderr)

        # Coleta inicial de posts.
        all_posts = await _extract_posts(page)
        if all_posts is None:
            all_posts = []

        seen_ids = set()
        seen_ids.update(p.get("platform_post_id") for p in all_posts if p.get("platform_post_id"))
        unique_posts = list(all_posts)

        scroll_wait_timeout = float(os.environ.get("TWITTER_SCROLL_TIMEOUT", SCROLL_SETTLE_TIMEOUT))
        stagnation_count = 0

        for iteration in range(MAX_SCROLL_ITERATIONS):
            if len(unique_posts) >= limit:
                break

            prev_height = await page.evaluate("document.body.scrollHeight")
            await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")

            waited_ids, new_ids, new_height, height_changed = await wait_for_scroll_progress(
                page, seen_ids, prev_height, timeout=scroll_wait_timeout
            )

            # Nota: NÃO atualizamos seen_ids com waited_ids aqui.
            # wait_for_scroll_progress já detectou os novos IDs durante o
            # polling (via _collect_tweet_ids), mas os posts completos ainda
            # serão extraídos abaixo por _extract_posts. Se marcássos como
            # "vistos" agora, o loop de deduplicação descartaria 100% dos
            # posts recém-carregados. seen_ids é atualizado incrementalmente
            # dentro do loop de processamento de new_posts.

            new_posts = await _extract_posts(page)
            if new_posts is None:
                new_posts = []

            added = 0
            for post in new_posts:
                pid = post.get("platform_post_id")
                if pid and pid in seen_ids:
                    continue
                if pid:
                    seen_ids.add(pid)
                unique_posts.append(post)
                added += 1
                if len(unique_posts) >= limit:
                    break

            # Estratégia: encerrar após STAGNATION_THRESHOLD iterações
            # consecutivas sem novo ID e sem mudança de altura.
            if added == 0 and not height_changed:
                stagnation_count += 1
                if stagnation_count >= STAGNATION_THRESHOLD:
                    break
            else:
                stagnation_count = 0

        return unique_posts[:limit]
    finally:
        await browser.stop()


async def _extract_posts(page):
    """Extrai posts do DOM atual. Retorna lista ou dict de erro."""
    result = await page.evaluate(
        """
        (function() {
            try {
                var articles = document.querySelectorAll('article[data-testid="tweet"]');
                var posts = [];
                articles.forEach(function(article) {
                    try {
                        var timeEl = article.querySelector('time');
                        var linkEl = timeEl ? timeEl.closest('a') : null;
                        var tweetText = article.querySelector('[data-testid="tweetText"]');
                        var userName = article.querySelector('[data-testid="User-Name"]');
                        var likes = article.querySelector('[data-testid="like"] span');
                        var retweets = article.querySelector('[data-testid="retweet"] span');
                        var replies = article.querySelector('[data-testid="reply"] span');

                        var permalink = linkEl ? linkEl.getAttribute('href') : null;
                        var postId = permalink ? permalink.split('/').pop() : null;
                        posts.push({
                            platform_post_id: postId,
                            post_type: 'tweet',
                            caption: tweetText ? tweetText.textContent : null,
                            likes_count: likes ? parseInt(likes.textContent.replace(/[^0-9]/g, '')) || null : null,
                            comments_count: replies ? parseInt(replies.textContent.replace(/[^0-9]/g, '')) || null : null,
                            shares_count: retweets ? parseInt(retweets.textContent.replace(/[^0-9]/g, '')) || null : null,
                            posted_at: timeEl ? timeEl.getAttribute('datetime') : null,
                            permalink: permalink ? 'https://x.com' + permalink : null,
                            is_video: !!article.querySelector('[data-testid="videoPlayer"]')
                        });
                    } catch(e) {}
                });
                return JSON.stringify(posts);
            } catch(e) {
                return JSON.stringify({error: e.message});
            }
        })()
        """
    )

    try:
        posts = json.loads(result)
        if isinstance(posts, dict) and posts.get("error"):
            return None
        if isinstance(posts, list):
            return posts
    except Exception:
        pass
    return []


def main():
    parser = argparse.ArgumentParser(description="Twitter/X scraper via Nodriver")
    parser.add_argument("username", help="Twitter username")
    parser.add_argument("--mode", choices=["profile", "posts"], default="profile")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--proxy", default=None)

    args = parser.parse_args()

    try:
        if args.mode == "profile":
            result = asyncio.run(scrape_profile(args.username, args.proxy))
        else:
            result = asyncio.run(scrape_posts(args.username, args.limit, args.proxy))

        if result:
            print(json.dumps(result))
        else:
            print(json.dumps({"error": "No data extracted"}))
            sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
