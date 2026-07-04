kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

./install-cilium.sh

kubeadm token create --print-join-command > ~/join-command.sh
chmod +x ~/join-command.sh

kubectl get nodes -o wide
kubectl get pods -A
