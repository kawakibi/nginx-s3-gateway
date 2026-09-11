#!env njs

/*
 * Copyright 2026 F5, Inc.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import s3gateway from "include/s3gateway.js";

globalThis.ngx = {};

function assertEqual(actual, expected) {
    if (actual !== expected) {
        throw `Actual: [${actual}] Expected: [${expected}]`;
    }
}

function printHeader(name) {
    console.log('## ' + name);
}

function request(path, headers) {
    const r = {
        method: 'GET', uri: path, headersIn: headers || {},
        variables: {
            uri_path: path, uri_full_path: path, request_uri: path,
            forIndexPage: 'false', s3_host: 'origin:9000'
        }
    };
    r.log = function (msg) { console.log(msg); };
    return r;
}

function testStaticDefault() {
    printHeader('testStaticDefault');
    delete process.env['ALLOW_DYNAMIC_BUCKET_NAME'];
    const r = request('/private/video.mp4', {'X-Bucket-Name': 'ignored'});
    assertEqual(s3gateway.getBucketName(r), process.env['S3_BUCKET_NAME']);
    assertEqual(s3gateway.missingBucketHeader(r), '');
    assertEqual(s3gateway.corsBucketHeader(r), '');
    process.env['ALLOW_DYNAMIC_BUCKET_NAME'] = 'false';
    assertEqual(s3gateway.getBucketName(r), process.env['S3_BUCKET_NAME']);
}

function testBucketSelectionAndSigning() {
    printHeader('testBucketSelectionAndSigning');
    process.env['ALLOW_DYNAMIC_BUCKET_NAME'] = 'YeS';
    process.env['S3_STYLE'] = 'path';
    delete process.env['HEADER_DYNAMIC_BUCKET_NAME'];
    const r = request('/private/video.mp4', {'x-bucket-name': 'bucket-a'});
    assertEqual(s3gateway.getBucketName(r), 'bucket-a');
    assertEqual(s3gateway.s3uri(r), '/bucket-a/private/video.mp4');
    assertEqual(s3gateway.corsBucketHeader(r), ',X-Bucket-Name');
    process.env['HEADER_DYNAMIC_BUCKET_NAME'] = '';
    assertEqual(s3gateway.getBucketName(r), 'bucket-a');
    process.env['HEADER_DYNAMIC_BUCKET_NAME'] = 'X-Custom-Bucket-Name';
    r.headersIn = {'X-CUSTOM-BUCKET-NAME': 'bucket-b', 'X-Bucket-Name': 'ignored'};
    assertEqual(s3gateway.getBucketName(r), 'bucket-b');
    assertEqual(s3gateway.missingBucketHeader(r), '');
    assertEqual(s3gateway.s3uri(r), '/bucket-b/private/video.mp4');
    assertEqual(s3gateway._s3ReqParamsForSigV2(r, 'bucket-b').uri,
        '/bucket-b/private/video.mp4');
    assertEqual(s3gateway._s3ReqParamsForSigV4(r, 'bucket-b', 'origin:9000').uri,
        '/bucket-b/private/video.mp4');
    assertEqual(s3gateway.corsBucketHeader(r), ',X-Custom-Bucket-Name');
}

function testMissingHeaderGuard() {
    printHeader('testMissingHeaderGuard');
    const paths = ['/private/video.mp4', '/site/index.html', '/site/', '/',
        '/health/index.html', '/soap/index.html'];
    for (let i = 0; i < paths.length; i++) {
        const r = request(paths[i]);
        assertEqual(s3gateway.getBucketName(r), undefined);
        assertEqual(s3gateway.missingBucketHeader(r), '1');
        r.method = 'HEAD';
        assertEqual(s3gateway.missingBucketHeader(r), '1');
        r.headersIn['X-Custom-Bucket-Name'] = '';
        assertEqual(s3gateway.missingBucketHeader(r), '1');
        r.headersIn = {'X-Bucket-Name': 'wrong-header'};
        assertEqual(s3gateway.missingBucketHeader(r), '1');
        r.internalRedirect = function (uri) { assertEqual(uri, '@error500'); };
        s3gateway.redirectToS3(r);
        r.method = 'OPTIONS';
        assertEqual(s3gateway.missingBucketHeader(r), '');
    }
    const localPaths = ['/health', '/soap', '/aws/credentials/retrieve'];
    for (let i = 0; i < localPaths.length; i++) {
        assertEqual(s3gateway.missingBucketHeader(request(localPaths[i])), '');
    }
}

async function testIndexProbePreservesBucket() {
    printHeader('testIndexProbePreservesBucket');
    const r = request('/viewer/site/', {
        'x-custom-bucket-name': 'bucket-b',
        Range: 'bytes=0-1', Authorization: 'must-not-be-forwarded'
    });
    r.variables.uri_path = '/internal/site/';
    let probeCount = 0;
    let nextStatus = 200;
    let redirect;
    r.internalRedirect = function (uri) { redirect = uri; };
    globalThis.ngx.fetch = function (url, options) {
        probeCount++;
        // Dockerfile.unprivileged rewrites the probe's port to 8080.
        if (!/^http:\/\/127\.0\.0\.1:(80|8080)\/viewer\/site\/index\.html$/.test(url)) {
            throw 'Index probe used an upstream-rewritten or bucket-prefixed URI: ' + url;
        }
        assertEqual(Object.keys(options.headers).length, 1);
        assertEqual(options.headers['X-Custom-Bucket-Name'], 'bucket-b');
        return Promise.resolve({status: nextStatus});
    };
    await s3gateway.loadContent(r);
    assertEqual(redirect, '/viewer/site/index.html');
    nextStatus = 404;
    await s3gateway.loadContent(r);
    assertEqual(redirect, '@s3Directory');
    assertEqual(probeCount, 2);
}

async function test() {
    const names = ['ALLOW_DYNAMIC_BUCKET_NAME', 'HEADER_DYNAMIC_BUCKET_NAME', 'S3_STYLE'];
    const saved = {};
    for (let i = 0; i < names.length; i++) saved[names[i]] = process.env[names[i]];
    try {
        testStaticDefault();
        testBucketSelectionAndSigning();
        testMissingHeaderGuard();
        await testIndexProbePreservesBucket();
    } finally {
        for (let i = 0; i < names.length; i++) {
            if (saved[names[i]] === undefined) delete process.env[names[i]];
            else process.env[names[i]] = saved[names[i]];
        }
    }
}

test();
console.log('Finished unit tests for dynamic buckets');
