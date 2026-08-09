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
        page = await browser.get(f"https://www.instagram.com/{username}/")
        await asyncio.sleep(5)

        result = await page.evaluate("""
            (function() {
                try {
                    var data = window._sharedData;
                    if (data && data.entry_data && data.entry_data.ProfilePage && data.entry_data.ProfilePage[0]) {
                        var user = data.entry_data.ProfilePage[0].graphql.user;
                        return JSON.stringify({
                            user_id: user.id,
                            username: user.username,
                            full_name: user.full_name,
                            biography: user.biography,
                            followers_count: user.edge_followed_by.count,
                            following_count: user.edge_follow.count,
                            posts_count: user.edge_owner_to_timeline_media.count,
                            is_private: user.is_private,
                            is_verified: user.is_verified,
                            profile_pic_url: user.profile_pic_url_hd,
                            avatar_url: user.profile_pic_url_hd
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


async def scrape_posts(username, limit=12, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))

    try:
        page = await browser.get(f"https://www.instagram.com/{username}/")
        await asyncio.sleep(5)

        all_posts = []
        scroll_attempts = 0
        max_scrolls = (limit // 12) + 2

        while len(all_posts) < limit and scroll_attempts < max_scrolls:
            result = await page.evaluate("""
                (function() {
                    try {
                        var data = window._sharedData;
                        if (data && data.entry_data && data.entry_data.ProfilePage && data.entry_data.ProfilePage[0]) {
                            var media = data.entry_data.ProfilePage[0].graphql.user.edge_owner_to_timeline_media;
                            var posts = media.edges.map(function(edge) {
                                var node = edge.node;
                                return {
                                    platform_post_id: node.id,
                                    post_type: node.__typename,
                                    caption: node.edge_media_to_caption.edges.length > 0 ? node.edge_media_to_caption.edges[0].node.text : null,
                                    likes_count: node.edge_media_preview_like ? node.edge_media_preview_like.count : null,
                                    comments_count: node.edge_media_to_comment ? node.edge_media_to_comment.count : null,
                                    posted_at: node.taken_at_timestamp,
                                    thumbnail_url: node.thumbnail_src,
                                    is_video: node.is_video,
                                    video_url: node.is_video ? node.video_url : null,
                                    shortcode: node.shortcode
                                };
                            });
                            return JSON.stringify(posts);
                        }
                        return null;
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
            await asyncio.sleep(3)
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
    parser = argparse.ArgumentParser(description="Instagram scraper via Nodriver")
    parser.add_argument("username", help="Instagram username")
    parser.add_argument("--mode", choices=["profile", "posts"], default="profile")
    parser.add_argument("--limit", type=int, default=12)
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
