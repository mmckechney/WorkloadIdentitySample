#Depending on the operating system of the host machines(s) that will build or run the containers, the image specified in the FROM statement may need to be changed.
#For more information, please see https://aka.ms/containercompat 

FROM mcr.microsoft.com/dotnet/framework/sdk:4.8-windowsservercore-ltsc2019 AS build

COPY . ./src/
WORKDIR /src
RUN nuget restore
RUN msbuild IdentitySample.sln /t:ResolveReferences /t:_WPPCopyWebApplication /p:Configuration=Release /p:BuildingProject=true /p:OutDir=..\PUBLISH


FROM mcr.microsoft.com/dotnet/framework/aspnet:4.8-windowsservercore-ltsc2019 AS runtime
WORKDIR /inetpub/wwwroot
COPY --from=build src/PUBLISH/_PublishedWebsites/IdentitySample/ ./
