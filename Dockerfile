FROM arkhotech/github-action-image:1.1

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/ || exit 1

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && chown appuser:appgroup /entrypoint.sh

USER appuser
 
ENTRYPOINT [ "/entrypoint.sh" ]
