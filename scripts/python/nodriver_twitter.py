#!/usr/bin/env python3

import asyncio
import json
import argparse
import sys

try:
    import nodriver as uc
except ImportError:
    print(json.dumps({"error": "nodriver not installed"}), file=sys.stderr)
    sys.exit(1)

import browser_binary


async def scrape_profile(username, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))

    try:
        page = await browser.get(f"https://x.com/{username}")
        await asyncio.sleep(6)

        result = await page.evaluate("""
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
                            username: username,
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
        """)

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
        await asyncio.sleep(6)

        all_posts = []
        scroll_attempts = 0
        max_scrolls = (limit // 5) + 3

        while len(all_posts) < limit and scroll_attempts < max_scrolls:
            result = await page.evaluate("""
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
            """)

            if not result:
                break

            posts = json.loads(result)
            if isinstance(posts, dict) and posts.get("error"):
                break

            for post in posts:
                if len(all_posts) >= limit:
                    break
                all_posts.append(post)

            await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            await asyncio.sleep(4)
            scroll_attempts += 1

        seen = set()
        unique_posts = []
        for post in all_posts:
            pid = post.get("platform_post_id")
            if pid and pid not in seen:
                seen.add(pid)
                unique_posts.append(post)

        return unique_posts
    finally:
        await browser.stop()


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
